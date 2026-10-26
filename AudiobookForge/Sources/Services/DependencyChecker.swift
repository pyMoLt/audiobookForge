import Foundation

struct DependencyStatus: Identifiable, Sendable {
    enum State: Sendable { case ok(String), missing(String) }
    let id: String
    let name: String
    let state: State
}

enum DependencyChecker {
    static func checkFFmpeg(settings: AppSettings) -> DependencyStatus {
        if let url = FFmpegLocator.resolve(settings: settings) {
            return DependencyStatus(id: "ffmpeg", name: "ffmpeg", state: .ok(url.path))
        }
        return DependencyStatus(id: "ffmpeg", name: "ffmpeg", state: .missing(String(localized: "Nicht gefunden. Automatisch über Einrichtungsassistenten installierbar (oder per brew install ffmpeg)")))
    }

    static func checkPython() -> DependencyStatus {
        if RuntimeInstaller.shared.isStandalonePythonReady {
            return DependencyStatus(id: "python", name: "Python (AudiobookForge)", state: .ok(RuntimeInstaller.shared.pythonURL.path))
        }
        let candidates = [
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return DependencyStatus(id: "python", name: "Python (System)", state: .ok(c))
        }
        return DependencyStatus(id: "python", name: "Python", state: .missing(String(localized: "Nicht gefunden. Automatisch installierbar oder per brew install python@3.12")))
    }

    static func checkBridge(bridge: BridgeEnvironmentManager) -> DependencyStatus {
        if bridge.isEnvironmentReady() {
            return DependencyStatus(id: "kokoro", name: "Kokoro / mlx-audio", state: .ok(bridge.pythonExecutableURL.path))
        }
        return DependencyStatus(id: "kokoro", name: "Kokoro / mlx-audio", state: .missing(String(localized: "Noch nicht eingerichtet. Über den Button unten einrichten.")))
    }

    static func checkPiper(environment: PiperEnvironmentManager) -> DependencyStatus {
        if environment.isEnvironmentReady() {
            let downloaded = PiperVoiceCatalog.allVoices.filter { environment.isVoiceDownloaded($0.id) }.count
            return DependencyStatus(id: "piper", name: "Piper", state: .ok(String(localized: "Bereit, \(downloaded)/\(PiperVoiceCatalog.allVoices.count) Stimme(n) heruntergeladen")))
        }
        return DependencyStatus(id: "piper", name: "Piper", state: .missing(String(localized: "Noch nicht eingerichtet. Über den Button unten einrichten.")))
    }

    static func checkGermanKokoro(environment: GermanKokoroEnvironmentManager) -> DependencyStatus {
        let ready = GermanKokoroEnvironmentManager.supportedVoices.filter { environment.isVoiceReady($0) }
        let detail = ready.isEmpty ? String(localized: "Keine deutsche Kokoro-Stimme installiert") : String(localized: "Bereit: \(ready.joined(separator: ", "))")
        return DependencyStatus(id: "kokoroGerman", name: String(localized: "Kokoro Deutsch / MLX"),
                                state: ready.isEmpty ? .missing(detail) : .ok(detail))
    }

    static func checkSupertonic(environment: SupertonicEnvironmentManager) -> DependencyStatus {
        DependencyStatus(id: "supertonic3", name: "Supertonic 3 / MLX",
                         state: environment.isReady() ? .ok(environment.modelDirectory.path) : .missing(String(localized: "Modell oder MLX-Laufzeit fehlt; unter TTS-Engine installieren.")))
    }

    static func checkOmniVoice(environment: OmniVoiceEnvironmentManager) -> DependencyStatus {
        DependencyStatus(id: "omnivoice", name: "OmniVoice Diffusion",
                         state: environment.isReady() ? .ok(environment.modelDirectory()?.path ?? "Bereit") : .missing(String(localized: "Modell fehlt; unter Einstellungen → Engines & Downloads herunterladen.")))
    }

    static func checkPhonon(environment: PhononEnvironmentManager = .shared) -> DependencyStatus {
        let languages = environment.installedLanguages
        return DependencyStatus(id: "phonon", name: "Phonon (Gradium)",
                                state: environment.isEnvironmentReady() && !languages.isEmpty
                                    ? .ok(languages.map { $0.uppercased() }.joined(separator: ", "))
                                    : .missing(String(localized: "Laufzeit oder Sprachmodell fehlt; unter Einstellungen → Engines & Downloads laden.")))
    }

    static func checkPocket(environment: PocketEnvironmentManager = .shared) -> DependencyStatus {
        let languages = environment.installedLanguages
        return DependencyStatus(id: "pocket", name: "Pocket TTS (Kyutai)",
                                state: environment.isEnvironmentReady() && !languages.isEmpty
                                    ? .ok(languages.map { $0.uppercased() }.joined(separator: ", "))
                                    : .missing(String(localized: "Laufzeit oder Sprachmodell fehlt; unter Einstellungen → Engines & Downloads laden.")))
    }

    static func checkSystemVoices() -> DependencyStatus {
        let voices = AppleSpeechEngine.installedVoices()
        let premium = voices.filter { $0.quality == .premium }.count
        let enhanced = voices.filter { $0.quality == .enhanced }.count
        return DependencyStatus(id: "systemVoices", name: String(localized: "macOS-Systemstimmen"),
                                state: voices.isEmpty
                                    ? .missing(String(localized: "Keine deutschen/englischen Systemstimmen installiert."))
                                    : .ok(String(localized: "\(voices.count) Stimmen (Deutsch/Englisch), davon \(premium) Premium und \(enhanced) erweitert")))
    }

    static func checkLLMEndpoint(settings: AppSettings) async -> DependencyStatus {
        let client = SummarizerClient(settings: settings)
        switch await client.testConnection() {
        case .success(let models):
            return DependencyStatus(id: "llm", name: String(localized: "Lokaler LLM-Endpoint"), state: .ok(String(localized: "Erreichbar, \(models.count) Modell(e) geladen")))
        case .failure(let error):
            return DependencyStatus(id: "llm", name: String(localized: "Lokaler LLM-Endpoint"), state: .missing(error.localizedDescription))
        }
    }
}
