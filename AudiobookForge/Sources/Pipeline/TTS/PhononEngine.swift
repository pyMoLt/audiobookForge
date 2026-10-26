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

    func isReady(voice: String) async -> Bool {
        let (language, name) = Self.split(voice)
        return environment.isReady(language: language)
            && FileManager.default.fileExists(atPath: environment.voiceFileURL(language: language, name: name).path)
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
        let script = try environment.bridgeScriptURL()
        let plan = BridgeSpeechPlan(text: text, determinismKey: outputURL.path, settings: settings)
        guard !plan.segments.isEmpty else { throw TTSEngineError.processFailed("Kein Text zum Vorlesen gefunden.") }
        let planURL = try plan.write()
        defer { try? FileManager.default.removeItem(at: planURL) }
        let segmentsURL = outputURL.deletingPathExtension().appendingPathExtension("segments.json")
        defer { try? FileManager.default.removeItem(at: segmentsURL) }

        return try await PCMBridgeRunner.run(
            executable: environment.pythonExecutableURL,
            arguments: [
                "-I", script.path,
                "--plan", planURL.path,
                "--model", environment.modelDirectory(for: language).path,
                "--voice", name,
                "--lang", language,
                "--quant", "q8",
                "--threads", "1",
                "--duration-delta", String(format: "%.3f", Self.durationDelta(forSpeed: speed)),
                "--segments-json", segmentsURL.path,
            ],
            segmentsURL: segmentsURL,
            outputURL: outputURL,
            settings: settings,
            onProgress: onProgress
        )
    }
}
