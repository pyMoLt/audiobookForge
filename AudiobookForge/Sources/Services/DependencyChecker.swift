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
        return DependencyStatus(id: "ffmpeg", name: "ffmpeg", state: .missing("Nicht gefunden. Installation: brew install ffmpeg"))
    }

    static func checkBridge(bridge: BridgeEnvironmentManager) -> DependencyStatus {
        if bridge.isEnvironmentReady() {
            return DependencyStatus(id: "kokoro", name: "Kokoro / mlx-audio", state: .ok(bridge.pythonExecutableURL.path))
        }
        return DependencyStatus(id: "kokoro", name: "Kokoro / mlx-audio", state: .missing("Noch nicht eingerichtet. Über den Button unten einrichten."))
    }

    static func checkPiper(environment: PiperEnvironmentManager) -> DependencyStatus {
        if environment.isEnvironmentReady() {
            let downloaded = PiperVoiceCatalog.allVoices.filter { environment.isVoiceDownloaded($0.id) }.count
            return DependencyStatus(id: "piper", name: "Piper", state: .ok("Bereit, \(downloaded)/\(PiperVoiceCatalog.allVoices.count) Stimme(n) heruntergeladen"))
        }
        return DependencyStatus(id: "piper", name: "Piper", state: .missing("Noch nicht eingerichtet. Über den Button unten einrichten."))
    }

    static func checkGermanKokoro(environment: GermanKokoroEnvironmentManager) -> DependencyStatus {
        let ready = GermanKokoroEnvironmentManager.supportedVoices.filter { environment.isVoiceReady($0) }
        let detail = ready.isEmpty ? "Keine deutsche Kokoro-Stimme installiert" : "Bereit: \(ready.joined(separator: ", "))"
        return DependencyStatus(id: "kokoroGerman", name: "Kokoro Deutsch / MLX",
                                state: ready.isEmpty ? .missing(detail) : .ok(detail))
    }

    static func checkSupertonic(environment: SupertonicEnvironmentManager) -> DependencyStatus {
        DependencyStatus(id: "supertonic3", name: "Supertonic 3 / MLX",
                         state: environment.isReady() ? .ok(environment.modelDirectory.path) : .missing("Modell oder MLX-Laufzeit fehlt; unter TTS-Engine installieren."))
    }

    static func checkLLMEndpoint(settings: AppSettings) async -> DependencyStatus {
        let client = SummarizerClient(settings: settings)
        switch await client.testConnection() {
        case .success(let models):
            return DependencyStatus(id: "llm", name: "Lokaler LLM-Endpoint", state: .ok("Erreichbar, \(models.count) Modell(e) geladen"))
        case .failure(let error):
            return DependencyStatus(id: "llm", name: "Lokaler LLM-Endpoint", state: .missing(error.localizedDescription))
        }
    }
}
