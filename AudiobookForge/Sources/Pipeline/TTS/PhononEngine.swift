import Foundation

/// One Phonon catalog voice (bundled list, so the gallery shows voices
/// before their language model is downloaded).
struct PhononVoice: Codable, Hashable, Sendable {
    let name: String
    let language: String
    let locale: String
    let gender: String
    let description: String
    /// Gradium's own ranking within locale and gender (1 = best).
    var rank: Int?

    /// Engine voice id: "<lang>/<Name>", e.g. "de/Henrik".
    var id: String { "\(language)/\(name)" }

    static let catalog: [PhononVoice] = {
        guard let url = Bundle.main.url(forResource: "phonon_voices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let voices = try? JSONDecoder().decode([PhononVoice].self, from: data) else { return [] }
        return voices
    }()
}

/// Phonon 40m (Gradium) via the `ptts` runtime (v4). Fastest engine
/// measured on Apple silicon: CPU, q8 weights, one thread per process —
/// several chapters render in parallel (one process each).
struct PhononEngine: TTSEngine {
    let id: TTSEngineID = .phonon
    let settings: AppSettings
    let environment: PhononEnvironmentManager

    static func split(_ voice: String) -> (language: String, name: String) {
        let parts = voice.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : ("de", voice)
    }

    /// Speaking-rate condition for a tempo factor: measured on 40m-de,
    /// speech length ≈ 1 + 0.6·delta, reliable within −0.6…+0.3.
    static func durationDelta(forSpeed speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        let delta = (1 / speed - 1) / 0.6
        return min(0.3, max(-0.6, delta))
    }

    func availableVoices() -> [TTSVoiceOption] {
        PhononVoice.catalog.map { voice in
            let gender = voice.gender == "female" ? "weiblich" : "männlich"
            return TTSVoiceOption(id: voice.id, displayName: "\(voice.name) (\(voice.locale), \(gender))")
        }
    }

    func isReady() async -> Bool { environment.isEnvironmentReady() && !environment.installedLanguages.isEmpty }

    /// Model folder that speaks a language (English: 40m or 31m, v4.2).
    func model(for language: String) -> String {
        PhononEnvironmentManager.modelKey(language: language, english31m: settings.phononEnglish31m)
    }

    func isReady(voice: String) async -> Bool {
        let (language, name) = Self.split(voice)
        let model = model(for: language)
        return environment.isReady(language: model)
            && FileManager.default.fileExists(atPath: environment.voiceFileURL(language: model, name: name).path)
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        let (language, name) = Self.split(voice)
        guard await isReady(voice: voice) else {
            throw TTSEngineError.notReady(L("Phonon-Sprachmodell oder Stimme fehlt. Bitte unter Einstellungen → Engines & Downloads laden.") + " (\(voice))")
        }
        let plan = BridgeSpeechPlan(text: text, determinismKey: outputURL.path, settings: settings)
        guard !plan.segments.isEmpty else { throw TTSEngineError.processFailed("Kein Text zum Vorlesen gefunden.") }
        // v4.1: in the power-saving profile, speak on the Neural Engine when
        // the language is prepared. Tempo is fixed in the Core ML export, so
        // a changed tempo stays on the CPU runtime.
        if Self.usesNeuralEngine(profile: PowerProfile.current, speed: speed, temperature: settings.phononTemperature,
                                 refinementSteps: settings.phononRefinementSteps, neuralReady: environment.isNeuralReady(model(for: language))) {
            return try await synthesizeOnNeuralEngine(plan: plan, voice: name, language: language, outputURL: outputURL, onProgress: onProgress)
        }
        let script = try environment.bridgeScriptURL()
        let planURL = try plan.write()
        defer { try? FileManager.default.removeItem(at: planURL) }
        let segmentsURL = outputURL.deletingPathExtension().appendingPathExtension("segments.json")
        defer { try? FileManager.default.removeItem(at: segmentsURL) }

        return try await PCMBridgeRunner.run(
            executable: environment.pythonExecutableURL,
            arguments: [
                "-I", script.path,
                "--plan", planURL.path,
                "--model", environment.modelDirectory(for: model(for: language)).path,
                "--voice", name,
                "--lang", language,
                "--quant", "q8",
                "--threads", "1",
                "--duration-delta", String(format: "%.3f", Self.durationDelta(forSpeed: speed)),
                "--temperature", String(format: "%.3f", settings.phononTemperature),
                "--lsd-steps", String(max(1, settings.phononRefinementSteps)),
                "--segments-json", segmentsURL.path,
            ],
            segmentsURL: segmentsURL,
            outputURL: outputURL,
            settings: settings,
            onProgress: onProgress
        )
    }

    /// Tempo, temperature and refinement steps are fixed in the Core ML
    /// runtime, so only the defaults run on the Neural Engine; anything
    /// else stays on the CPU.
    static func usesNeuralEngine(profile: PowerMode, speed: Double, temperature: Double = ExpressionDefaults.temperature,
                                 refinementSteps: Int = 1, neuralReady: Bool) -> Bool {
        profile == .saver && abs(speed - 1) < 0.01 && ExpressionDefaults.isStandard(temperature, ExpressionDefaults.temperature)
            && refinementSteps <= 1 && neuralReady
    }

    private func synthesizeOnNeuralEngine(
        plan: BridgeSpeechPlan, voice: String, language: String, outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        let rate = 24_000
        let encoder = try ChapterAudioEncoder.start(sampleRate: rate, outputURL: outputURL, settings: settings, stdinPipe: Pipe())
        @Sendable func silence(_ ms: Int) -> Data { Data(count: rate * ms / 1000 * 2) }
        let timeline = LockedBox<(cursor: Double, segments: [TTSSegment])>((0, []))
        do {
            onProgress(.modelLoaded)
            onProgress(.plannedSegments(plan.segments.count))
            if plan.lead_in_ms > 0 {
                try encoder.write(silence(plan.lead_in_ms))
                timeline.withLock { $0.cursor += Double(plan.lead_in_ms) / 1000 }
            }
            try await PhononNeuralEngine.shared.synthesize(
                segments: plan.segments, voice: voice, language: language,
                directory: environment.neuralDirectory(for: model(for: language))
            ) { index, samples in
                var pcm = Data(capacity: samples.count * 2)
                for sample in samples {
                    var value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
                try encoder.write(pcm)
                var duration = Double(samples.count) / Double(rate)
                let pause = index < plan.pauses_ms.count ? plan.pauses_ms[index] : 0
                if pause > 0 {
                    try encoder.write(silence(pause))
                    duration += Double(pause) / 1000
                }
                timeline.withLock { state in
                    state.segments.append(TTSSegment(index: index, startSeconds: state.cursor, durationSeconds: duration, text: plan.segments[index]))
                    state.cursor += duration
                }
                onProgress(.segmentDone(index: index, durationSeconds: duration))
            }
            if plan.tail_ms > 0 { try encoder.write(silence(plan.tail_ms)) }
            let total = try await encoder.finish()
            let segments = timeline.withLock { $0.segments }
            return TTSSynthesisResult(audioFileURL: outputURL, durationSeconds: total, segmentCount: segments.count, segments: segments)
        } catch {
            encoder.abort()
            throw error
        }
    }
}
