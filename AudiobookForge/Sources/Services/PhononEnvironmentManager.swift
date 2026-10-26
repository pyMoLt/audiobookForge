import Foundation

/// Phonon (Gradium, v4): a small venv with the `ptts` runtime plus one
/// 40m model folder per language under models/phonon/<lang>/ (config,
/// tokenizer, q8 weights, that language's voices). The models are gated:
/// downloads use the Hugging Face sign-in (`HuggingFaceAccount`).
final class PhononEnvironmentManager: @unchecked Sendable {
    static let shared = PhononEnvironmentManager()

    /// Languages Gradium publishes a 40m model for (Italian has none).
    static let languages = ["de", "en", "fr", "es"]

    static func repo(for language: String) -> String { "gradium/phonon-40m-\(language)" }

    let directory: URL
    let modelsRoot: URL

    init(root: URL = AppPaths.applicationSupportDirectory) {
        directory = root.appendingPathComponent("bridge_phonon", isDirectory: true)
        modelsRoot = root.appendingPathComponent("models/phonon", isDirectory: true)
    }

    var pythonExecutableURL: URL { directory.appendingPathComponent(".venv/bin/python") }

    func isEnvironmentReady() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: pythonExecutableURL.path) else { return false }
        let lib = directory.appendingPathComponent(".venv/lib")
        let versions = (try? fm.contentsOfDirectory(atPath: lib.path)) ?? []
        return versions.contains { fm.fileExists(atPath: lib.appendingPathComponent("\($0)/site-packages/ptts").path) }
    }

    func modelDirectory(for language: String) -> URL {
        modelsRoot.appendingPathComponent(language, isDirectory: true)
    }

    func isModelReady(_ language: String) -> Bool {
        let dir = modelDirectory(for: language)
        let fm = FileManager.default
        return ["config.json", "tokenizer.json", "model.q8.gguf"].allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    var installedLanguages: [String] { Self.languages.filter(isModelReady) }

    func isReady(language: String) -> Bool { isEnvironmentReady() && isModelReady(language) }

    func voiceFileURL(language: String, name: String) -> URL {
        modelDirectory(for: language).appendingPathComponent("voices/\(name).safetensors")
    }

    func modelSizeOnDisk(_ language: String) -> Int64 {
        let dir = modelDirectory(for: language)
        guard let items = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Install

    private func bundled(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: name, withExtension: ext) else {
            throw BridgeEnvironmentError.resourcesMissing
        }
        return url
    }

    func bridgeScriptURL() throws -> URL { try bundled("phonon_bridge", "py") }

    /// Creates/repairs the venv with the ptts runtime.
    func setupEnvironment(onOutput: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = try bundled("setup_phonon_env", "sh")
        let status = try await ScriptRunner.run(executable: URL(fileURLWithPath: "/bin/bash"),
                                                arguments: [script.path, directory.path], onLine: onOutput)
        guard status == 0, isEnvironmentReady() else { throw BridgeEnvironmentError.setupFailed(exitCode: status) }
    }

    enum InstallError: LocalizedError {
        case termsRequired(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .termsRequired(let repo):
                return L("Bitte zuerst auf Hugging Face anmelden und den Nutzungsbedingungen des Modells zustimmen:") + " \(repo)"
            case .failed(let message): return message
            }
        }
    }

    /// Downloads one language model plus its voices (sets up the runtime first if needed).
    func installModel(_ language: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        if !isEnvironmentReady() { try await setupEnvironment(onOutput: onOutput) }
        let script = try bundled("setup_phonon_model", "py")
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let gated = LockedBox(false)
        let lastError = LockedBox<String?>(nil)
        let status = try await ScriptRunner.run(
            executable: pythonExecutableURL,
            arguments: ["-I", script.path, "--lang", language, "--models-root", modelsRoot.path],
            environment: HuggingFaceAccount.processEnvironment()
        ) { line in
            if line.hasPrefix("ERROR GATED") { gated.withLock { $0 = true } }
            if line.hasPrefix("ERROR ") { lastError.withLock { $0 = String(line.dropFirst(6)) } }
            onOutput(line)
        }
        if gated.withLock({ $0 }) { throw InstallError.termsRequired(Self.repo(for: language)) }
        guard status == 0, isModelReady(language) else {
            throw InstallError.failed(lastError.withLock { $0 } ?? "Download von \(Self.repo(for: language)) fehlgeschlagen (Code \(status)).")
        }
    }

    func removeModel(_ language: String) throws {
        let dir = modelDirectory(for: language)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }
}
