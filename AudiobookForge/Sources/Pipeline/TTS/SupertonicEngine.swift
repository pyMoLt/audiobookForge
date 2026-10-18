import Foundation

struct SupertonicEngine: TTSEngine {
    let id: TTSEngineID = .supertonic3
    let settings: AppSettings
    let environment: SupertonicEnvironmentManager

    func availableVoices() -> [TTSVoiceOption] {
        (1...5).map { TTSVoiceOption(id: "M\($0)", displayName: "M\($0) (männlich)") }
            + (1...5).map { TTSVoiceOption(id: "F\($0)", displayName: "F\($0) (weiblich)") }
    }

    func isReady() async -> Bool { environment.isReady() }

    func isReady(voice: String) async -> Bool {
        environment.isReady()
            && availableVoices().contains(where: { $0.id == voice })
            && FileManager.default.fileExists(atPath: environment.modelDirectory.appendingPathComponent("voice_styles/\(voice).json").path)
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        guard await isReady(voice: voice) else {
            throw TTSEngineError.notReady("Supertonic 3 MLX oder Stimme \(voice) fehlt. Bitte in den Einstellungen einrichten.")
        }
        try Task.checkCancellation()
        let bridge = BridgeEnvironmentManager.shared
        guard let script = Bundle.main.url(forResource: "supertonic_bridge", withExtension: "py", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "supertonic_bridge", withExtension: "py") else {
            throw BridgeEnvironmentError.resourcesMissing
        }

        let textURL = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookForge-supertonic-\(UUID().uuidString).txt")
        try text.write(to: textURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: textURL) }
        let segmentsURL = outputURL.deletingPathExtension().appendingPathExtension("segments.json")
        defer { try? FileManager.default.removeItem(at: segmentsURL) }

        let process = Process()
        process.executableURL = bridge.pythonExecutableURL
        process.arguments = [
            script.path,
            "--text-file", textURL.path,
            "--model", environment.modelDirectory.path,
            "--runtime", environment.runtimeDirectory.path,
            "--voice", voice,
            "--speed", String(speed),
            "--steps", String(settings.supertonicSteps),
            "--chunk-characters", String(settings.supertonicChunkCharacters),
            "--pause-seconds", String(settings.supertonicPauseSeconds),
            "--segments-json", segmentsURL.path,
        ]

        // The bridge streams raw s16le PCM on stdout; ffmpeg (started once
        // SAMPLE_RATE arrives on stderr) consumes it kernel-side and writes
        // only the small compressed chapter file.
        let pcmPipe = Pipe()
        process.standardOutput = pcmPipe

        struct BridgeState {
            var duration = 0.0
            var count = 0
            var errorMessage: String?
            var encoder: ChapterAudioEncoder?
            var lineBuffer = ""
        }
        let state = LockedBox(BridgeState())
        let cancelled = LockedBox(false)
        let processBox = LockedBox(process)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let completeLines: [String] = state.withLock { current in
                current.lineBuffer += text
                var lines: [String] = []
                while let newlineRange = current.lineBuffer.range(of: "\n") {
                    let line = String(current.lineBuffer[current.lineBuffer.startIndex..<newlineRange.lowerBound])
                    current.lineBuffer.removeSubrange(current.lineBuffer.startIndex..<newlineRange.upperBound)
                    lines.append(line)
                }
                return lines
            }

            for line in completeLines {
                if line == "MODEL_LOADED" {
                    onProgress(.modelLoaded)
                } else if line.hasPrefix("SAMPLE_RATE ") {
                    if let rate = Int(line.dropFirst("SAMPLE_RATE ".count)) {
                        do {
                            let encoder = try ChapterAudioEncoder.start(sampleRate: rate, outputURL: outputURL, settings: settings, stdinPipe: pcmPipe)
                            state.withLock { $0.encoder = encoder }
                        } catch {
                            // Without ffmpeg the pipe has no reader — kill
                            // the bridge now instead of letting it block on
                            // a full pipe buffer forever.
                            state.withLock { $0.errorMessage = "ffmpeg konnte nicht gestartet werden: \(error.localizedDescription)" }
                            processBox.withLock { if $0.isRunning { $0.terminate() } }
                        }
                    }
                } else if line.hasPrefix("SEGMENTS_TOTAL "), let total = Int(line.dropFirst("SEGMENTS_TOTAL ".count)) {
                    onProgress(.plannedSegments(total))
                } else if line.hasPrefix("SEGMENT_DONE ") {
                    let fields = line.split(separator: " ")
                    if fields.count == 3, let index = Int(fields[1]), let duration = Double(fields[2]) {
                        state.withLock { $0.count = max($0.count, index + 1) }
                        onProgress(.segmentDone(index: index, durationSeconds: duration))
                    }
                } else if line.hasPrefix("DONE ") {
                    let fields = line.split(separator: " ")
                    if fields.count == 3, let duration = Double(fields[1]), let count = Int(fields[2]) {
                        state.withLock {
                            $0.duration = duration
                            $0.count = count
                        }
                    }
                } else if line.hasPrefix("ERROR ") {
                    let message = String(line.dropFirst("ERROR ".count))
                    state.withLock { $0.errorMessage = message }
                }
            }
        }

        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let errorMessage = state.withLock { $0.errorMessage }
                if cancelled.withLock({ $0 }) {
                    state.withLock { $0.encoder?.abort() }
                    continuation.resume(throwing: CancellationError())
                } else if proc.terminationStatus == 0, errorMessage == nil {
                    continuation.resume()
                } else {
                    // Producer died mid-stream: ffmpeg must not keep a
                    // partial chapter file around.
                    state.withLock { $0.encoder?.abort() }
                    continuation.resume(throwing: TTSEngineError.processFailed(errorMessage ?? "Exit-Code \(proc.terminationStatus)"))
                }
            }

            do {
                try process.run()
                if cancelled.withLock({ $0 }) { process.terminate() }
            } catch {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
          }
        } onCancel: {
            cancelled.withLock { $0 = true }
            processBox.withLock { if $0.isRunning { $0.terminate() } }
            state.withLock { $0.encoder?.abort() }
        }

        let encoder = state.withLock { $0.encoder }
        guard let encoder else {
            let message = state.withLock { $0.errorMessage }
            throw TTSEngineError.processFailed(message ?? "Die Bridge hat keine SAMPLE_RATE-Zeile gesendet — keine PCM-Daten kodiert.")
        }
        let duration = try await encoder.finish()

        struct SegmentFile: Decodable { let segments: [TTSSegment] }
        let segments = (try? Data(contentsOf: segmentsURL)).flatMap { try? JSONDecoder().decode(SegmentFile.self, from: $0).segments }
        let finalCount = state.withLock { $0.count }
        return TTSSynthesisResult(audioFileURL: outputURL, durationSeconds: duration,
                                  segmentCount: segments?.count ?? finalCount, segments: segments)
    }
}
