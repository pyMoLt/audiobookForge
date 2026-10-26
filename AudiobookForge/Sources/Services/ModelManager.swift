import Foundation

struct ModelItem: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let engineID: TTSEngineID
    let license: String
    let estimatedSizeBytes: Int64
    let huggingFaceRepo: String?

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: estimatedSizeBytes, countStyle: .file)
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        engineID: TTSEngineID,
        license: String,
        estimatedSizeBytes: Int64,
        huggingFaceRepo: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.engineID = engineID
        self.license = license
        self.estimatedSizeBytes = estimatedSizeBytes
        self.huggingFaceRepo = huggingFaceRepo
    }
}

final class ModelManager: @unchecked Sendable {
    static let shared = ModelManager()

    private let bridge = BridgeEnvironmentManager.shared
    private let germanKokoro = GermanKokoroEnvironmentManager.shared
    private let supertonic = SupertonicEnvironmentManager.shared
    private let piper = PiperEnvironmentManager.shared
    private let omniVoice = OmniVoiceEnvironmentManager.shared

    init() {}

    // MARK: - Catalog Definition

    var availableModels: [ModelItem] {
        [
            ModelItem(
                id: "kokoro-de-martin",
                title: "Kokoro Deutsch: Martin",
                subtitle: "Klare, natürliche deutsche Stimme",
                engineID: .kokoroGerman,
                license: "Apache 2.0 (kikiri)",
                estimatedSizeBytes: 155_000_000,
                huggingFaceRepo: "semidark/kikiri-tts"
            ),
            ModelItem(
                id: "kokoro-de-victoria",
                title: "Kokoro Deutsch: Victoria",
                subtitle: "Weibliche deutsche Referenzstimme",
                engineID: .kokoroGerman,
                license: "Apache 2.0 (kikiri)",
                estimatedSizeBytes: 155_000_000,
                huggingFaceRepo: "semidark/kikiri-tts"
            ),
            ModelItem(
                id: "kokoro-de-thorsten",
                title: "Kokoro Deutsch: Thorsten",
                subtitle: "Bekannte freie Community-Stimme",
                engineID: .kokoroGerman,
                license: "CC0 (Public Domain)",
                estimatedSizeBytes: 155_000_000,
                huggingFaceRepo: "semidark/kikiri-tts"
            ),
            ModelItem(
                id: "piper-de-thorsten-high",
                title: "Piper: Thorsten High",
                subtitle: "Höchste Audioauflösung für Piper (Deutsch)",
                engineID: .piper,
                license: "CC0",
                estimatedSizeBytes: 120_000_000,
                huggingFaceRepo: "rhasspy/piper-voices"
            ),
            ModelItem(
                id: "piper-de-thorsten-medium",
                title: "Piper: Thorsten Medium",
                subtitle: "Schnelle, ressourcenschonende deutsche Stimme",
                engineID: .piper,
                license: "CC0",
                estimatedSizeBytes: 65_000_000,
                huggingFaceRepo: "rhasspy/piper-voices"
            ),
            ModelItem(
                id: "piper-de-eva_k",
                title: "Piper: Eva K",
                subtitle: "Weibliche deutsche Stimme",
                engineID: .piper,
                license: "CC-BY-4.0",
                estimatedSizeBytes: 65_000_000,
                huggingFaceRepo: "rhasspy/piper-voices"
            ),
            ModelItem(
                id: "supertonic-3",
                title: "Supertonic 3",
                subtitle: "Streaming-TTS mit geringer Latenz",
                engineID: .supertonic3,
                license: "Apache 2.0",
                estimatedSizeBytes: 125_000_000,
                huggingFaceRepo: "supertonic-ai/supertonic-3"
            ),
            ModelItem(
                id: "omnivoice-base",
                title: "OmniVoice Diffusion",
                subtitle: "Standard-Klon-Engine für eigene Stimmen (600+ Sprachen)",
                engineID: .omniVoice,
                license: "Apache 2.0",
                estimatedSizeBytes: 2_040_000_000,
                huggingFaceRepo: "mlx-community/OmniVoice-bfloat16"
            ),
        ]
    }

    // MARK: - Status Checking

    func isInstalled(_ item: ModelItem) -> Bool {
        switch item.id {
        case "kokoro-de-martin":
            return germanKokoro.isVoiceReady("martin")
        case "kokoro-de-victoria":
            return germanKokoro.isVoiceReady("victoria")
        case "kokoro-de-thorsten":
            return germanKokoro.isVoiceReady("thorsten")
        case "piper-de-thorsten-high":
            return piper.isVoiceDownloaded("de_DE-thorsten-high")
        case "piper-de-thorsten-medium":
            return piper.isVoiceDownloaded("de_DE-thorsten-medium")
        case "piper-de-eva_k":
            return piper.isVoiceDownloaded("de_DE-eva_k-x_low") || piper.isVoiceDownloaded("de_DE-eva_k")
        case "supertonic-3":
            return supertonic.isReady()
        case "omnivoice-base":
            return omniVoice.isReady()
        default:
            return false
        }
    }

    // MARK: - Installation & Removal

    func install(
        _ item: ModelItem,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        switch item.id {
        case "kokoro-de-martin":
            try await germanKokoro.install("martin", onOutput: onOutput)
        case "kokoro-de-victoria":
            try await germanKokoro.install("victoria", onOutput: onOutput)
        case "kokoro-de-thorsten":
            try await germanKokoro.install("thorsten", onOutput: onOutput)

        case "piper-de-thorsten-high":
            if let voice = PiperVoiceCatalog.allVoices.first(where: { $0.id == "de_DE-thorsten-high" }) {
                try await piper.downloadVoice(voice) { frac in onOutput("Download: \(Int(frac * 100))%") }
            }
        case "piper-de-thorsten-medium":
            if let voice = PiperVoiceCatalog.allVoices.first(where: { $0.id == "de_DE-thorsten-medium" }) {
                try await piper.downloadVoice(voice) { frac in onOutput("Download: \(Int(frac * 100))%") }
            }
        case "piper-de-eva_k":
            if let voice = PiperVoiceCatalog.allVoices.first(where: { $0.id == "de_DE-eva_k-x_low" }) ?? PiperVoiceCatalog.allVoices.first(where: { $0.id == "de_DE-eva_k" }) {
                try await piper.downloadVoice(voice) { frac in onOutput("Download: \(Int(frac * 100))%") }
            }

        case "supertonic-3":
            try await supertonic.install(onOutput: onOutput)

        case "omnivoice-base":
            try await downloadHuggingFaceSnapshot(
                repoID: "mlx-community/OmniVoice-bfloat16",
                targetSubfolder: "omnivoice",
                onOutput: onOutput
            )

        default:
            throw TTSEngineError.notReady("Unbekanntes Modell: \(item.id)")
        }
    }

    func delete(_ item: ModelItem) throws {
        let fm = FileManager.default
        switch item.id {
        case "kokoro-de-martin":
            let dir = germanKokoro.modelDirectory(for: "martin")
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        case "kokoro-de-victoria":
            let dir = germanKokoro.modelDirectory(for: "victoria")
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        case "kokoro-de-thorsten":
            let dir = germanKokoro.modelDirectory(for: "thorsten")
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }

        case "piper-de-thorsten-high":
            let onnx = piper.onnxURL(for: "de_DE-thorsten-high")
            let cfg = piper.onnxConfigURL(for: "de_DE-thorsten-high")
            if fm.fileExists(atPath: onnx.path) { try fm.removeItem(at: onnx) }
            if fm.fileExists(atPath: cfg.path) { try fm.removeItem(at: cfg) }

        case "piper-de-thorsten-medium":
            let onnx = piper.onnxURL(for: "de_DE-thorsten-medium")
            let cfg = piper.onnxConfigURL(for: "de_DE-thorsten-medium")
            if fm.fileExists(atPath: onnx.path) { try fm.removeItem(at: onnx) }
            if fm.fileExists(atPath: cfg.path) { try fm.removeItem(at: cfg) }

        case "piper-de-eva_k":
            for id in ["de_DE-eva_k-x_low", "de_DE-eva_k"] {
                let onnx = piper.onnxURL(for: id)
                let cfg = piper.onnxConfigURL(for: id)
                if fm.fileExists(atPath: onnx.path) { try? fm.removeItem(at: onnx) }
                if fm.fileExists(atPath: cfg.path) { try? fm.removeItem(at: cfg) }
            }

        case "supertonic-3":
            if fm.fileExists(atPath: supertonic.modelDirectory.path) {
                try fm.removeItem(at: supertonic.modelDirectory)
            }
            if fm.fileExists(atPath: supertonic.runtimeDirectory.path) {
                try fm.removeItem(at: supertonic.runtimeDirectory)
            }

        case "omnivoice-base":
            let dir = AppPaths.modelsDirectory.appendingPathComponent("omnivoice", isDirectory: true)
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }

        default:
            break
        }
    }

    // MARK: - Snapshot Downloader Helper

    private func downloadHuggingFaceSnapshot(
        repoID: String,
        targetSubfolder: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        guard bridge.isEnvironmentReady() else {
            throw TTSEngineError.notReady(L("Kokoro-MLX-Umgebung zuerst unter Einstellungen → Engines & Downloads einrichten."))
        }

        let targetDir = AppPaths.modelsDirectory.appendingPathComponent(targetSubfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        onOutput("Starte Download von \(repoID) nach \(targetDir.lastPathComponent) …")

        let pythonCode = """
import sys
from huggingface_hub import snapshot_download

repo_id = "\(repoID)"
local_dir = "\(targetDir.path)"
print(f"STEP Lade Snapshot {repo_id}...")
path = snapshot_download(repo_id=repo_id, local_dir=local_dir)
print(f"DONE Modell erfolgreich gespeichert unter {path}")
"""

        let process = Process()
        process.executableURL = bridge.pythonExecutableURL
        process.arguments = ["-c", pythonCode]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                text.split(separator: "\n", omittingEmptySubsequences: true).forEach { line in
                    onOutput(String(line))
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TTSEngineError.processFailed("Download von \(repoID) fehlgeschlagen (Code \(proc.terminationStatus))."))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
