import Foundation

/// The speech plan handed to the v4 bridges (Phonon, Pocket TTS): the
/// app's PausePlanner decides segments and pauses, the bridge only speaks.
/// So every engine gets the same rhythm and every segment its exact text.
struct BridgeSpeechPlan: Codable, Sendable {
    var segments: [String]
    var pauses_ms: [Int]
    var lead_in_ms: Int
    var tail_ms: Int

    init(text: String, determinismKey: String, settings: AppSettings) {
        let planned = PausePlanner.plan(text)
        let pauses = PausePlanner.pausePlan(for: planned, determinismKey: determinismKey, settings: settings)
        segments = planned.map(\.text)
        pauses_ms = pauses.pauseAfterMs
        lead_in_ms = pauses.leadInMs
        tail_ms = pauses.tailMs
    }

    /// Writes the plan to a temporary file (removed by the caller).
    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookForge-plan-\(UUID().uuidString).json")
        try JSONEncoder().encode(self).write(to: url)
        return url
    }
}

/// Runs a PCM-streaming bridge (s16le on stdout, progress lines on stderr:
/// MODEL_LOADED, SAMPLE_RATE n, SEGMENTS_TOTAL n, SEGMENT_DONE i d,
/// DONE d n, ERROR …) and pipes the audio straight into the chapter
/// encoder. Shared by the v4 engines; same protocol as the Supertonic bridge.
enum PCMBridgeRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        segmentsURL: URL,
        outputURL: URL,
        settings: AppSettings,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let pcmPipe = Pipe()
        process.standardOutput = pcmPipe

        struct BridgeState {
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
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            let lines: [String] = state.withLock { current in
                current.lineBuffer += text
                var out: [String] = []
                while let range = current.lineBuffer.range(of: "\n") {
                    out.append(String(current.lineBuffer[..<range.lowerBound]))
                    current.lineBuffer.removeSubrange(..<range.upperBound)
                }
                return out
            }
            for line in lines {
                if line == "MODEL_LOADED" {
                    onProgress(.modelLoaded)
                } else if line.hasPrefix("SAMPLE_RATE "), let rate = Int(line.dropFirst("SAMPLE_RATE ".count)) {
                    do {
                        let encoder = try ChapterAudioEncoder.start(sampleRate: rate, outputURL: outputURL, settings: settings, stdinPipe: pcmPipe)
                        state.withLock { $0.encoder = encoder }
                    } catch {
                        state.withLock { $0.errorMessage = "ffmpeg konnte nicht gestartet werden: \(error.localizedDescription)" }
                        processBox.withLock { if $0.isRunning { $0.terminate() } }
                    }
                } else if line.hasPrefix("SEGMENTS_TOTAL "), let total = Int(line.dropFirst("SEGMENTS_TOTAL ".count)) {
                    onProgress(.plannedSegments(total))
                } else if line.hasPrefix("SEGMENT_DONE ") {
                    let fields = line.split(separator: " ")
                    if fields.count == 3, let index = Int(fields[1]), let duration = Double(fields[2]) {
                        state.withLock { $0.count = max($0.count, index + 1) }
                        onProgress(.segmentDone(index: index, durationSeconds: duration))
                    }
                } else if line.hasPrefix("ERROR ") {
                    state.withLock { $0.errorMessage = String(line.dropFirst("ERROR ".count)) }
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
                        state.withLock { $0.encoder?.abort() }
                        continuation.resume(throwing: TTSEngineError.processFailed(errorMessage ?? "Exit-Code \(proc.terminationStatus)"))
                    }
                }
                do {
                    process.applyPowerProfile()
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

        guard let encoder = state.withLock({ $0.encoder }) else {
            throw TTSEngineError.processFailed(state.withLock { $0.errorMessage } ?? "Die Bridge hat keine SAMPLE_RATE-Zeile gesendet — keine PCM-Daten kodiert.")
        }
        let duration = try await encoder.finish()
        struct SegmentFile: Decodable { let segments: [TTSSegment] }
        let segments = (try? Data(contentsOf: segmentsURL)).flatMap { try? JSONDecoder().decode(SegmentFile.self, from: $0).segments }
        return TTSSynthesisResult(audioFileURL: outputURL, durationSeconds: duration,
                                  segmentCount: segments?.count ?? state.withLock { $0.count }, segments: segments)
    }
}
