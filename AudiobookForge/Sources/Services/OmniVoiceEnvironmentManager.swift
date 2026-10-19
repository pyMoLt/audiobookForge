import Foundation

/// Locates the OmniVoice MLX model directory (mlx-community/OmniVoice-bfloat16,
/// ~2 GB). The model is deliberately NOT downloaded automatically: the user
/// downloads it once (`hf download mlx-community/OmniVoice-bfloat16` or via
/// LM Studio) and this manager finds it in one of the known locations.
final class OmniVoiceEnvironmentManager: @unchecked Sendable {
    static let shared = OmniVoiceEnvironmentManager()

    private let bridge = BridgeEnvironmentManager.shared

    var candidateModelDirectories: [URL] {
        var candidates: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. The app's own models directory (manual install).
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        candidates.append(appSupport.appendingPathComponent("AudiobookForge/models/omnivoice", isDirectory: true))

        // 2. LM Studio's model folder.
        candidates.append(home.appendingPathComponent(".lmstudio/models/mlx-community/OmniVoice-bfloat16", isDirectory: true))

        // 3. The Hugging Face cache (snapshot layout — where
        //    `hf download` / huggingface_hub put it).
        let cacheRoot = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let snapshots = cacheRoot
            .appendingPathComponent("models--mlx-community--OmniVoice-bfloat16", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: versions)
        }

        return candidates
    }

    /// The first candidate that actually looks like the model directory.
    func modelDirectory() -> URL? {
        let fm = FileManager.default
        return candidateModelDirectories.first { url in
            fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
                && fm.fileExists(atPath: url.appendingPathComponent("model.safetensors").path)
        }
    }

    func isReady() -> Bool {
        bridge.isEnvironmentReady() && modelDirectory() != nil
    }

    var setupHint: String {
        "OmniVoice-Modell nicht gefunden. Einmalig herunterladen: „hf download mlx-community/OmniVoice-bfloat16“ (≈2 GB, Hugging-Face-Cache) oder in den LM-Studio-Modellordner bzw. App-Modellordner legen."
    }
}
