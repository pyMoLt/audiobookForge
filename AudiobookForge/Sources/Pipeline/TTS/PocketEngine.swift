import Foundation

/// One published Pocket TTS voice. Every language model can speak every
/// voice; the native one per language is Kyutai's own recording in it.
struct PocketVoice: Hashable, Sendable {
    let name: String
    let female: Bool

    var displayName: String {
        name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static let all: [PocketVoice] = [
        ("alba", true), ("anna", true), ("azelma", true), ("bill_boerst", false), ("caro_davy", true), ("charles", false),
        ("cosette", true), ("eponine", true), ("estelle", true), ("eve", true), ("fantine", true), ("george", false),
        ("jane", true), ("javert", false), ("jean", false), ("juergen", false), ("lola", true), ("marius", false),
        ("mary", true), ("michael", false), ("paul", false), ("rafael", false), ("stuart_bell", false), ("vera", true),
    ].map { PocketVoice(name: $0.0, female: $0.1) }
}

/// Pocket TTS (Kyutai, v4) via its official runtime. Full engine with
/// local voice cloning; "high quality" switches to the 24-layer models.
/// Voice ids: "<lang>/<name>" (published voices) or "clone:<uuid>".
struct PocketEngine: TTSEngine {
    let id: TTSEngineID = .pocketTTS
    let settings: AppSettings
    let environment: PocketEnvironmentManager

    func availableVoices() -> [TTSVoiceOption] {
        PocketEnvironmentManager.languages.flatMap { language in
            PocketVoice.all.map { voice in
                TTSVoiceOption(id: "\(language)/\(voice.name)",
                               displayName: "\(voice.displayName) (\(language), \(voice.female ? "weiblich" : "männlich"))")
            }
        }
    }

    /// Language of a voice id; clones use their recording's language.
    func language(of voice: String) -> String {
        if voice.hasPrefix("clone:") {
            return VoiceCloneStore.shared.clone(forVoice: voice).map { String($0.languageCode.prefix(2)) } ?? "de"
        }
        return PhononEngine.split(voice).language
    }

    func isReady() async -> Bool { environment.isEnvironmentReady() && !environment.installedLanguages.isEmpty }

    func isReady(voice: String) async -> Bool {
        let language = language(of: voice)
        guard PocketEnvironmentManager.variants[language] != nil else { return false }
        if voice.hasPrefix("clone:"), VoiceCloneStore.shared.clone(forVoice: voice) == nil { return false }
        return environment.isReady(language: language, highQuality: settings.pocketHighQuality)
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        guard await isReady(voice: voice) else {
            throw TTSEngineError.notReady(L("Pocket-TTS-Sprachmodell fehlt. Bitte unter Einstellungen → Engines & Downloads laden.") + " (\(voice))")
        }
        let language = language(of: voice)
        let variant = PocketEnvironmentManager.variant(language: language, highQuality: settings.pocketHighQuality)
        var voiceArguments: [String]
        if voice.hasPrefix("clone:") {
            guard let clone = VoiceCloneStore.shared.clone(forVoice: voice),
                  let audioURL = VoiceCloneStore.shared.audioURL(for: clone) else {
                throw TTSEngineError.notReady("Eigene Stimme nicht gefunden: \(voice)")
            }
            voiceArguments = ["--voice-audio", audioURL.path,
                              "--voice-cache", environment.cloneStateURL(cloneID: clone.id, variant: variant).path]
        } else {
            voiceArguments = ["--voice", PhononEngine.split(voice).name]
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
            arguments: ["-I", script.path, "--plan", planURL.path, "--variant", variant, "--lang", language, "--threads", "1",
                        "--temperature", String(format: "%.3f", settings.pocketTemperature),
                        "--segments-json", segmentsURL.path] + voiceArguments,
            environment: environment.processEnvironment(),
            segmentsURL: segmentsURL,
            outputURL: outputURL,
            settings: settings,
            onProgress: onProgress
        )
    }
}
