import Foundation

/// OmniVoice engine (k2-fsa, MLX weights via mlx-audio): same bridge
/// pattern as Kokoro/Qwen3 — `omnivoice_bridge.py` streams raw s16le PCM
/// on stdout (piped into ffmpeg), protocol markers on stderr. One sentence
/// per line, driven by the pause planner, so read-along and the 8.4 pause
/// engine work identically.
///
/// Differences from Kokoro:
/// - Non-autoregressive masked-diffusion model: each segment needs a
///   maximum duration estimate (chars/sec heuristic in the bridge; trailing
///   padding is trimmed).
/// - No speed parameter — `speed` is accepted but ignored.
/// - One default voice for now; voice cloning via reference audio is a
///   possible follow-up (model supports it).
struct OmniVoiceEngine: TTSEngine {
    let id: TTSEngineID = .omniVoice

    private let settings: AppSettings
    private let environment: OmniVoiceEnvironmentManager
    private let bridge = BridgeEnvironmentManager.shared

    init(settings: AppSettings, environment: OmniVoiceEnvironmentManager) {
        self.settings = settings
        self.environment = environment
    }

    /// OmniVoice currently provides one built-in default voice (zero-shot
    /// cloning via reference audio is a model feature but not wired into
    /// the gallery yet).
    static let voices: [TTSVoiceOption] = [
        TTSVoiceOption(id: "default", displayName: "OmniVoice (Standardstimme)"),
    ]

    func availableVoices() -> [TTSVoiceOption] {
        Self.voices
    }

    func isReady() async -> Bool {
        await isReady(voice: "default")
    }

    func isReady(voice: String) async -> Bool {
        environment.isReady()
    }

    /// Maps a BCP-47-ish code to the tag OmniVoice expects (it accepts the
    /// BCP-47 tag directly; empty falls back to German).
    static func languageTag(for languageCode: String?) -> String {
        guard let code = languageCode?.lowercased(), !code.isEmpty else { return "de" }
        return String(code.prefix(2))
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        try Task.checkCancellation()
        guard environment.isReady(), let modelPath = environment.modelDirectory() else {
            throw TTSEngineError.notReady(environment.setupHint)
        }

        // Cloned voices ("clone:<uuid>") resolve to their reference audio;
        // preset voices ("default") use the model's built-in speaker.
        var refAudioPath: String?
        var refText: String?
        if voice.hasPrefix("clone:") {
            guard let clone = VoiceCloneStore.shared.clone(forVoice: voice) else {
                throw TTSEngineError.notReady("Die geklonte Stimme existiert nicht mehr — Stimmen-Galerie öffnen und neu anlegen.")
            }
            guard let audioURL = VoiceCloneStore.shared.audioURL(for: clone) else {
                throw TTSEngineError.notReady("Die Aufnahme der geklonten Stimme fehlt auf der Festplatte.")
            }
            refAudioPath = audioURL.path
            refText = clone.refText.isEmpty ? nil : clone.refText
        }

        // Same pause-planned, one-sentence-per-line scheme as Kokoro.
        let plannedSegments = PausePlanner.plan(text)
        let sentences = plannedSegments.map(\.text)
        guard !sentences.isEmpty else {
            throw TTSEngineError.processFailed("Kein Text zum Vorlesen gefunden.")
        }
        onProgress(.plannedSegments(sentences.count))
        let textFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookForge-chapter-\(UUID().uuidString).txt")
        try sentences.joined(separator: "\n").write(to: textFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: textFileURL) }

        let segmentsJSONURL = outputURL.deletingPathExtension().appendingPathExtension("segments.json")
        let pausePlan = PausePlanner.pausePlan(for: plannedSegments, determinismKey: outputURL.path, settings: settings)
        var pausesJSONURL: URL?
        if PausePlanner.containsSilence(pausePlan) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudiobookForge-pauses-\(UUID().uuidString).json")
            try JSONEncoder().encode(pausePlan).write(to: url)
            pausesJSONURL = url
        }
        defer { if let pausesJSONURL { try? FileManager.default.removeItem(at: pausesJSONURL) } }

        let process = Process()
        process.executableURL = bridge.pythonExecutableURL
        let scriptURL = Bundle.main.url(forResource: "omnivoice_bridge", withExtension: "py", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "omnivoice_bridge", withExtension: "py")
            ?? bridge.bridgeScriptURL.deletingLastPathComponent().appendingPathComponent("omnivoice_bridge.py")
        var arguments = [
            scriptURL.path,
            "--text-file", textFileURL.path,
            "--model", modelPath.path,
            "--language", Self.languageTag(for: LanguageDetector.detectLanguageCode(sampleText: text)),
            "--num-steps", String(max(4, min(64, settings.omniVoiceSteps))),
            "--segments-json", segmentsJSONURL.path,
        ]
        if let pausesJSONURL {
            arguments += ["--pauses-json", pausesJSONURL.path]
        }
        if let refAudioPath {
            arguments += ["--ref-audio", refAudioPath]
            if let refText {
                arguments += ["--ref-text", refText]
            }
        }
        arguments += ["--speed", String(speed)]
        process.arguments = arguments

        let pcmPipe = Pipe()
        process.standardOutput = pcmPipe

        struct BridgeState {
            var totalDuration = 0.0
            var segmentCount = 0
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
                            state.withLock { $0.errorMessage = "ffmpeg konnte nicht gestartet werden: \(error.localizedDescription)" }
                            processBox.withLock { if $0.isRunning { $0.terminate() } }
                        }
                    }
                } else if line.hasPrefix("SEGMENT_DONE ") {
                    let parts = line.dropFirst("SEGMENT_DONE ".count).split(separator: " ")
                    if parts.count == 2, let index = Int(parts[0]), let duration = Double(parts[1]) {
                        state.withLock { $0.segmentCount = max($0.segmentCount, index + 1) }
                        onProgress(.segmentDone(index: index, durationSeconds: duration))
                    }
                } else if line.hasPrefix("DONE ") {
                    let parts = line.dropFirst("DONE ".count).split(separator: " ")
                    if parts.count == 2, let duration = Double(parts[0]), let count = Int(parts[1]) {
                        state.withLock {
                            $0.totalDuration = duration
                            $0.segmentCount = count
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

        let encoder = state.withLock { $0.encoder }
        guard let encoder else {
            let message = state.withLock { $0.errorMessage }
            throw TTSEngineError.processFailed(message ?? "Die Bridge hat keine SAMPLE_RATE-Zeile gesendet — keine PCM-Daten kodiert.")
        }
        let duration = try await encoder.finish()

        let finalSegmentCount = state.withLock { $0.segmentCount }
        let segments = readSegments(from: segmentsJSONURL, segmentTexts: plannedSegments.map(\.text))
        try? FileManager.default.removeItem(at: segmentsJSONURL)
        return TTSSynthesisResult(
            audioFileURL: outputURL,
            durationSeconds: duration,
            segmentCount: finalSegmentCount > 0 ? finalSegmentCount : sentences.count,
            segments: segments
        )
    }

    /// The bridge reports start/duration per planned line but not the source
    /// text slice; pair by index with the same plan that produced the lines.
    private func readSegments(from url: URL, segmentTexts: [String]) -> [TTSSegment]? {
        struct BridgeSegment: Decodable { let index: Int; let startSeconds: Double; let durationSeconds: Double; let text: String? }
        struct BridgeSegmentsFile: Decodable { let segments: [BridgeSegment] }

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(BridgeSegmentsFile.self, from: data),
              !decoded.segments.isEmpty else {
            return nil
        }

        let textForIndex: (Int) -> String? = { index in
            segmentTexts.indices.contains(index) && segmentTexts.count == decoded.segments.count ? segmentTexts[index] : nil
        }

        return decoded.segments.map { segment in
            TTSSegment(index: segment.index, startSeconds: segment.startSeconds, durationSeconds: segment.durationSeconds, text: segment.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? textForIndex(segment.index))
        }
    }
}
