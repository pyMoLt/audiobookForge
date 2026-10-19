import Foundation

/// Second `TTSEngine` implementation, proving the engine seam from
/// `TTSEngine.swift` is real: nothing outside this file (and
/// `PiperEnvironmentManager`) knows Piper exists. Piper is a native CLI
/// (via the `piper-tts` pip package) with pre-trained voices such as the
/// German "Thorsten" voices, downloaded on demand.
///
/// Synthesizes sentence-by-sentence (rather than feeding the whole chapter
/// to one `piper` invocation) so that: (a) no single inference has to
/// process an unusually long run of text, and (b) we get real per-sentence
/// timing, matching the segment data Kokoro already provides — needed for
/// the sentence-accurate playback position.
///
/// Each sentence's raw 16-bit PCM is streamed straight from `piper
/// --output-raw` through ffmpeg's stdin — no per-sentence WAV and no
/// concatenated chapter WAV ever touches the disk, only the small
/// compressed chapter file.
struct PiperEngine: TTSEngine {
    let id: TTSEngineID = .piper

    private let settings: AppSettings
    private let environment: PiperEnvironmentManager

    init(settings: AppSettings, environment: PiperEnvironmentManager) {
        self.settings = settings
        self.environment = environment
    }

    func availableVoices() -> [TTSVoiceOption] {
        PiperVoiceCatalog.allVoices.map { TTSVoiceOption(id: $0.id, displayName: $0.displayName) }
    }

    func isReady() async -> Bool {
        environment.isEnvironmentReady() && environment.isVoiceDownloaded(settings.piperVoice)
    }

    func isReady(voice: String) async -> Bool {
        environment.isEnvironmentReady() && environment.isVoiceDownloaded(voice)
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        guard environment.isEnvironmentReady() else {
            throw TTSEngineError.notReady("Piper-Umgebung ist nicht eingerichtet. Bitte in den Einstellungen unter Diagnose einrichten.")
        }
        guard environment.isVoiceDownloaded(voice) else {
            throw TTSEngineError.notReady("Piper-Stimme '\(voice)' wurde noch nicht heruntergeladen.")
        }

        // App-side pause engine (plan 8.4): Swift writes the planned
        // silence itself — as zero bytes straight into the encoder's PCM
        // stream — so segment timing (and read-along) includes the pauses.
        let plannedSegments = PausePlanner.plan(text)
        let sentences = plannedSegments.map(\.text)
        guard !sentences.isEmpty else {
            throw TTSEngineError.processFailed("Kein Text zum Vorlesen gefunden.")
        }
        let pausePlan = PausePlanner.pausePlan(for: plannedSegments, determinismKey: outputURL.path, settings: settings)

        onProgress(.modelLoaded)
        onProgress(.plannedSegments(sentences.count))

        let sampleRate = voiceSampleRate(voice: voice)
        let encoder = try ChapterAudioEncoder.start(sampleRate: sampleRate, outputURL: outputURL, settings: settings, stdinPipe: Pipe())

        func silenceBytes(milliseconds: Int) -> Data {
            Data(count: Int(Double(sampleRate) * Double(milliseconds) / 1000.0) * 2)
        }

        do {
            var segments: [TTSSegment] = []
            var cumulative = 0.0

            if pausePlan.leadInMs > 0 {
                try encoder.write(silenceBytes(milliseconds: pausePlan.leadInMs))
                cumulative += Double(pausePlan.leadInMs) / 1000.0
            }

            for (index, sentence) in sentences.enumerated() {
                try Task.checkCancellation()
                let byteCount = try await synthesizeSentence(sentence, voice: voice, speed: speed, encoder: encoder)
                var duration = Double(byteCount) / (2.0 * Double(sampleRate))
                let pauseMs = index < pausePlan.pauseAfterMs.count ? pausePlan.pauseAfterMs[index] : 0
                if pauseMs > 0 {
                    try encoder.write(silenceBytes(milliseconds: pauseMs))
                    duration += Double(pauseMs) / 1000.0
                }

                segments.append(TTSSegment(index: index, startSeconds: cumulative, durationSeconds: duration, text: sentence))
                cumulative += duration
                onProgress(.segmentDone(index: index, durationSeconds: duration))
            }

            if pausePlan.tailMs > 0 {
                try encoder.write(silenceBytes(milliseconds: pausePlan.tailMs))
                cumulative += Double(pausePlan.tailMs) / 1000.0
            }

            let duration = try await encoder.finish()
            return TTSSynthesisResult(audioFileURL: outputURL, durationSeconds: duration, segmentCount: sentences.count, segments: segments)
        } catch {
            encoder.abort()
            throw error
        }
    }

    /// The voice's ONNX companion config carries the model's sample rate
    /// (e.g. 22050 for the Thorsten voices). `--output-raw` PCM has no
    /// header, so ffmpeg needs it up front.
    private func voiceSampleRate(voice: String) -> Int {
        let configURL = environment.onnxConfigURL(for: voice)
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audio = json["audio"] as? [String: Any],
              let rate = (audio["sample_rate"] as? Int) ?? (audio["sample_rate"] as? NSNumber)?.intValue else {
            return 22050
        }
        return max(8000, rate)
    }

    /// Streams one sentence's raw PCM from piper's stdout into the shared
    /// encoder. Returns the number of PCM bytes written, from which the
    /// sentence's exact duration is derived.
    private func synthesizeSentence(_ sentence: String, voice: String, speed: Double, encoder: ChapterAudioEncoder) async throws -> Int {
        try Task.checkCancellation()
        let modelURL = environment.onnxURL(for: voice)
        let configURL = environment.onnxConfigURL(for: voice)

        let process = Process()
        process.executableURL = environment.piperExecutableURL
        let lengthScale = 1.0 / max(0.25, speed)
        process.arguments = [
            "-m", modelURL.path,
            "-c", configURL.path,
            "--output-raw",
            "--length-scale", String(lengthScale),
            // "Lebendigkeit" (plan 8.5): prosodic variance / pronunciation
            // noise, editable in Erweitert.
            "--noise-scale", String(settings.piperNoiseScale),
            "--noise-w", String(settings.piperNoiseW),
        ]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = stderrPipe

        let byteCount = LockedBox<Int>(0)
        let errorLines = LockedBox<[String]>([])
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            errorLines.withLock { $0.append(text) }
        }
        // Forward PCM straight into ffmpeg's stdin (blocking write = natural
        // backpressure: piper stalls until ffmpeg has consumed the data).
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            byteCount.withLock { $0 += data.count }
            try? encoder.write(data)
        }

        let cancelled = LockedBox(false)
        let processBox = LockedBox(process)

        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Drain whatever piper wrote just before exiting but the
                // readability handler may not have forwarded yet (EOF is
                // guaranteed now that the process is gone).
                let trailing = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailing.isEmpty, proc.terminationStatus == 0 {
                    byteCount.withLock { $0 += trailing.count }
                    try? encoder.write(trailing)
                }
                if cancelled.withLock({ $0 }) {
                    continuation.resume(throwing: CancellationError())
                } else if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let joined = errorLines.withLock { $0.joined() }
                    continuation.resume(throwing: TTSEngineError.processFailed(joined.isEmpty ? "Exit-Code \(proc.terminationStatus)" : joined))
                }
            }

            do {
                process.applyPowerProfile()
                try process.run()
                if cancelled.withLock({ $0 }) { process.terminate() }
                if let data = (sentence + "\n").data(using: .utf8) {
                    // Throwing Swift API (an ObjC `write` would raise an
                    // uncatchable exception when piper already exited).
                    try inputPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inputPipe.fileHandleForWriting.close()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
          }
        } onCancel: {
            cancelled.withLock { $0 = true }
            processBox.withLock { if $0.isRunning { $0.terminate() } }
        }

        return byteCount.withLock { $0 }
    }
}
