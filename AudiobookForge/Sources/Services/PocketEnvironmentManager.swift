import Foundation

/// Pocket TTS (Kyutai, v4): a venv with the official `pocket-tts` runtime
/// (PyTorch CPU) and the app's own Hugging Face cache under
/// models/pocket/hub (so models can be listed and removed from the app).
/// One model per language, optionally the 24-layer "high quality" variant.
final class PocketEnvironmentManager: @unchecked Sendable {
    static let shared = PocketEnvironmentManager()

    /// App language code → pocket-tts language config.
    static let variants: [String: String] = ["de": "german", "en": "english", "fr": "french", "es": "spanish", "it": "italian"]
    static let languages = ["de", "en", "fr", "es", "it"]
    static let repo = "kyutai/pocket-tts"

    /// Native voice per language (Kyutai's own recording in that language;
    /// the Italian one ships with the 24-layer models only).
    static func nativeVoice(_ language: String, highQuality: Bool) -> String {
        switch language {
        case "de": return "juergen"
        case "fr": return "estelle"
        case "es": return "lola"
        case "it": return highQuality ? "giovanni" : "marius"
        default: return "alba"
        }
    }

    let directory: URL
    let hubCache: URL

    init(root: URL = AppPaths.applicationSupportDirectory) {
        directory = root.appendingPathComponent("bridge_pocket", isDirectory: true)
        hubCache = root.appendingPathComponent("models/pocket/hub", isDirectory: true)
    }

    var pythonExecutableURL: URL { directory.appendingPathComponent(".venv/bin/python") }

    static func variant(language: String, highQuality: Bool) -> String {
        let base = variants[language] ?? "english"
        // English ships its newest checkpoint under a dated name.
        if highQuality { return base == "english" ? "english_2026-09_24l" : "\(base)_24l" }
        return base
    }

    func isEnvironmentReady() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: pythonExecutableURL.path) else { return false }
        let lib = directory.appendingPathComponent(".venv/lib")
        let versions = (try? fm.contentsOfDirectory(atPath: lib.path)) ?? []
        return versions.contains { fm.fileExists(atPath: lib.appendingPathComponent("\($0)/site-packages/pocket_tts").path) }
    }

    /// Snapshot folders of the Pocket repos in the app's cache.
    private func snapshots() -> [URL] {
        let fm = FileManager.default
        return ["models--kyutai--pocket-tts", "models--kyutai--pocket-tts-without-voice-cloning"].flatMap { repo -> [URL] in
            let dir = hubCache.appendingPathComponent("\(repo)/snapshots", isDirectory: true)
            return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        }
    }

    func isModelReady(_ language: String, highQuality: Bool = false) -> Bool {
        let variant = Self.variant(language: language, highQuality: highQuality)
        return snapshots().contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("languages/\(variant)/model.safetensors").path)
        }
    }

    func isReady(language: String, highQuality: Bool) -> Bool {
        isEnvironmentReady() && isModelReady(language, highQuality: highQuality)
    }

    var installedLanguages: [String] { Self.languages.filter { isModelReady($0) } }

    /// Environment for every Pocket process: the app's model cache, the
    /// Hugging Face sign-in, no telemetry.
    func processEnvironment() -> [String: String] {
        var env = HuggingFaceAccount.processEnvironment()
        env["HF_HUB_CACHE"] = hubCache.path
        return env
    }

    private func bundled(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: name, withExtension: ext) else {
            throw BridgeEnvironmentError.resourcesMissing
        }
        return url
    }

    func bridgeScriptURL() throws -> URL { try bundled("pocket_bridge", "py") }

    func setupEnvironment(onOutput: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = try bundled("setup_pocket_env", "sh")
        let status = try await ScriptRunner.run(executable: URL(fileURLWithPath: "/bin/bash"),
                                                arguments: [script.path, directory.path], onLine: onOutput)
        guard status == 0, isEnvironmentReady() else { throw BridgeEnvironmentError.setupFailed(exitCode: status) }
    }

    func installModel(_ language: String, highQuality: Bool, onOutput: @escaping @Sendable (String) -> Void) async throws {
        if !isEnvironmentReady() { try await setupEnvironment(onOutput: onOutput) }
        let script = try bundled("setup_pocket_model", "py")
        try FileManager.default.createDirectory(at: hubCache, withIntermediateDirectories: true)
        let variant = Self.variant(language: language, highQuality: highQuality)
        let gated = LockedBox(false)
        let lastError = LockedBox<String?>(nil)
        let status = try await ScriptRunner.run(
            executable: pythonExecutableURL,
            arguments: ["-I", script.path, "--variant", variant, "--voices", Self.nativeVoice(language, highQuality: highQuality)],
            environment: processEnvironment()
        ) { line in
            if line.hasPrefix("ERROR GATED") { gated.withLock { $0 = true } }
            if line.hasPrefix("ERROR ") { lastError.withLock { $0 = String(line.dropFirst(6)) } }
            onOutput(line)
        }
        if gated.withLock({ $0 }) { throw PhononEnvironmentManager.InstallError.termsRequired(Self.repo) }
        guard status == 0, isModelReady(language, highQuality: highQuality) else {
            throw PhononEnvironmentManager.InstallError.failed(lastError.withLock { $0 } ?? "Download von Pocket TTS \(variant) fehlgeschlagen (Code \(status)).")
        }
    }

    /// Removes one language variant's weights and voices from the cache —
    /// including the data behind the snapshot links (v4.2; before, only the
    /// links went and the space stayed taken).
    func removeModel(_ language: String, highQuality: Bool) throws {
        let dirs = modelDirectories(language, highQuality: highQuality)
        if !dirs.isEmpty { try HFCacheJanitor.remove(dirs, hubRoot: hubCache) }
    }

    func modelDirectories(_ language: String, highQuality: Bool) -> [URL] {
        let variant = Self.variant(language: language, highQuality: highQuality)
        return snapshots().map { $0.appendingPathComponent("languages/\(variant)", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Cached state of a cloned voice for one model variant.
    func cloneStateURL(cloneID: UUID, variant: String) -> URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("voice_clones/\(cloneID.uuidString).pocket-\(variant).safetensors")
    }
}
