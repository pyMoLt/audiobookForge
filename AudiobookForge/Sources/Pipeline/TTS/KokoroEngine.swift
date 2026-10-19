import Foundation

/// Only current `TTSEngine` implementation. Talks to Kokoro through a
/// Python subprocess (mlx-audio) rather than linking anything Kokoro-specific
/// into the rest of the app — see `TTSEngine.swift` for the seam.
struct KokoroEngine: TTSEngine {
    let id: TTSEngineID

    private let settings: AppSettings
    private let bridge: BridgeEnvironmentManager

    init(settings: AppSettings, bridge: BridgeEnvironmentManager, id: TTSEngineID = .kokoro) {
        self.settings = settings
        self.bridge = bridge
        self.id = id
    }

    static let standardVoices: [TTSVoiceOption] = [
        TTSVoiceOption(id: "af_heart", displayName: "Heart (US, weiblich)"),
        TTSVoiceOption(id: "af_alloy", displayName: "Alloy (US, weiblich)"),
        TTSVoiceOption(id: "af_bella", displayName: "Bella (US, weiblich)"),
        TTSVoiceOption(id: "af_nicole", displayName: "Nicole (US, weiblich)"),
        TTSVoiceOption(id: "af_sarah", displayName: "Sarah (US, weiblich)"),
        TTSVoiceOption(id: "af_sky", displayName: "Sky (US, weiblich)"),
        TTSVoiceOption(id: "am_adam", displayName: "Adam (US, männlich)"),
        TTSVoiceOption(id: "am_michael", displayName: "Michael (US, männlich)"),
        TTSVoiceOption(id: "am_onyx", displayName: "Onyx (US, männlich)"),
        TTSVoiceOption(id: "am_puck", displayName: "Puck (US, männlich)"),
        TTSVoiceOption(id: "bf_emma", displayName: "Emma (UK, weiblich)"),
        TTSVoiceOption(id: "bf_lily", displayName: "Lily (UK, weiblich)"),
        TTSVoiceOption(id: "bm_daniel", displayName: "Daniel (UK, männlich)"),
        TTSVoiceOption(id: "bm_george", displayName: "George (UK, männlich)"),
    ]

    func availableVoices() -> [TTSVoiceOption] {
        switch id {
        case .kokoro: return Self.standardVoices
        case .kokoroGerman:
            return [TTSVoiceOption(id: "martin", displayName: "Martin (DE, männlich)"),
                    TTSVoiceOption(id: "victoria", displayName: "Victoria (DE, weiblich)")]
        case .kokoroThorsten:
            return [TTSVoiceOption(id: "thorsten", displayName: "Thorsten (DE, männlich)")]
        default: return []
        }
    }

    func isReady() async -> Bool {
        await isReady(voice: settings.defaultVoice(for: id))
    }

    func isReady(voice: String) async -> Bool {
        guard bridge.isEnvironmentReady() else { return false }
        switch id {
        case .kokoro: return true
        case .kokoroGerman, .kokoroThorsten:
            return GermanKokoroEnvironmentManager.shared.isVoiceReady(voice)
        default: return false
        }
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        try Task.checkCancellation()
        guard await isReady(voice: voice) else {
            throw TTSEngineError.notReady("Kokoro-Umgebung ist nicht eingerichtet. Bitte in den Einstellungen unter Diagnose einrichten.")
        }

        let isGerman = id == .kokoroGerman || id == .kokoroThorsten
        let modelPath = isGerman
            ? GermanKokoroEnvironmentManager.shared.modelDirectory(for: voice).path
            : settings.kokoroModelRepo
        let voiceArgument = isGerman
            ? GermanKokoroEnvironmentManager.shared.voiceURL(for: voice).path
            : voice
        let languageCode = isGerman ? "g" : String(voice.first ?? "a")

        // mlx-audio's Kokoro splits its input at every newline
        // (`split_pattern=r"\n+"`) and synthesizes each piece separately, so
        // a hard line wrap inside a sentence (common in PDF text) used to
        // become an audible pause mid-sentence. Hand it exactly one sentence
        // per line instead: no mid-sentence breaks, one segment per
        // sentence (so read-along text lines up), and a known segment count
        // for exact progress. The same plan also drives the app-side pause
        // engine (plan 8.4): one planned segment = one bridge line, so the
        // per-segment pauses in --pauses-json line up 1:1.
        let plannedSegments = PausePlanner.plan(text)
        let sentences = plannedSegments.map(\.text)
        guard !sentences.isEmpty else {
            throw TTSEngineError.processFailed("Kein Text zum Vorlesen gefunden.")
        }
        onProgress(.plannedSegments(sentences.count))
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let textFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookForge-chapter-\(UUID().uuidString).txt")
        try sentences.joined(separator: "\n").write(to: textFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: textFileURL) }

        let segmentsJSONURL = outputURL.deletingPathExtension().appendingPathExtension("segments.json")

        // Pause plan (plan 8.4). The output path is the determinism seed:
        // stable across regenerations of the same chapter, so a
        // re-synthesized chapter sounds identical.
        let pausePlan = PausePlanner.pausePlan(for: plannedSegments, determinismKey: outputURL.path, settings: settings)
        var pausesJSONURL: URL?
        if PausePlanner.containsSilence(pausePlan) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudiobookForge-pauses-\(UUID().uuidString).json")
            let encoded = try JSONEncoder().encode(pausePlan)
            try encoded.write(to: url)
            pausesJSONURL = url
        }
        defer { if let pausesJSONURL { try? FileManager.default.removeItem(at: pausesJSONURL) } }

        let process = Process()
        process.executableURL = bridge.pythonExecutableURL
        let scriptURL = Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py")
            ?? bridge.bridgeScriptURL
        var arguments = [
            scriptURL.path,
            "--text-file", textFileURL.path,
            "--voice", voiceArgument,
            "--speed", String(speed),
            "--model", modelPath,
            "--lang-code", languageCode,
            "--segments-json", segmentsJSONURL.path,
        ]
        if let pausesJSONURL {
            arguments += ["--pauses-json", pausesJSONURL.path]
        }
        process.arguments = arguments

        // PCM flows kernel-side: the bridge streams raw s16le into this
        // pipe and ffmpeg (started as soon as the bridge reports its sample
        // rate) reads the other end — no uncompressed audio ever lands on
        // disk, only the small compressed chapter file.
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
                            // Without ffmpeg the pipe has no reader — kill
                            // the bridge now instead of letting it block on
                            // a full pipe buffer forever.
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
                    // Producer died mid-stream: ffmpeg must not keep a
                    // partial chapter file around.
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

        // Bridge finished cleanly: ffmpeg now owns the pipe's write end
        // until finish() closes it, then finalizes the chapter file.
        let encoder = state.withLock { $0.encoder }
        guard let encoder else {
            let message = state.withLock { $0.errorMessage }
            throw TTSEngineError.processFailed(message ?? "Die Bridge hat keine SAMPLE_RATE-Zeile gesendet — keine PCM-Daten kodiert.")
        }
        let duration = try await encoder.finish()

        let finalSegmentCount = state.withLock { $0.segmentCount }
        let segments = readSegments(from: segmentsJSONURL, fullText: text)
        try? FileManager.default.removeItem(at: segmentsJSONURL)
        return TTSSynthesisResult(audioFileURL: outputURL, durationSeconds: duration, segmentCount: finalSegmentCount, segments: segments)
    }

    /// The bridge script reports segment start/duration/token-count but not
    /// the source text slice (mlx-audio doesn't expose that). We pair
    /// segments with our own sentence split by index on the reasonable
    /// assumption that Kokoro's internal chunking is close to sentence
    /// granularity; if the counts don't line up we just leave `text` nil
    /// rather than guess wrong.
    private func readSegments(from url: URL, fullText: String) -> [TTSSegment]? {
        struct BridgeSegment: Decodable { let index: Int; let startSeconds: Double; let durationSeconds: Double; let text: String? }
        struct BridgeSegmentsFile: Decodable { let segments: [BridgeSegment] }

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(BridgeSegmentsFile.self, from: data),
              !decoded.segments.isEmpty else {
            return nil
        }

        // One bridge line per planned segment (see synthesize) — pair with
        // the SAME plan, not a separate sentence split (that was off by one
        // wherever headings or lists differ).
        let sentences = PausePlanner.plan(fullText).map(\.text)
        let textForIndex: (Int) -> String? = { index in
            sentences.indices.contains(index) && sentences.count == decoded.segments.count ? sentences[index] : nil
        }

        return decoded.segments.map { segment in
            TTSSegment(index: segment.index, startSeconds: segment.startSeconds, durationSeconds: segment.durationSeconds,
                       text: segment.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? textForIndex(segment.index))
        }
    }
}
