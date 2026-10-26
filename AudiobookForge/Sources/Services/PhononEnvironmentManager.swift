import Foundation

/// Phonon (Gradium, v4): a small venv with the `ptts` runtime plus one
/// 40m model folder per language under models/phonon/<lang>/ (config,
/// tokenizer, q8 weights, that language's voices). The models are gated:
/// downloads use the Hugging Face sign-in (`HuggingFaceAccount`).
final class PhononEnvironmentManager: @unchecked Sendable {
    static let shared = PhononEnvironmentManager()

    /// Languages Gradium publishes a 40m model for (Italian has none).
    static let languages = ["de", "en", "fr", "es"]
    /// Model keys = folders under models/phonon (v4.2): the 40m model of
    /// each language plus English 31m — a little smaller and faster (~5 %),
    /// Apache 2.0 and not gated.
    static let models = languages + ["en-31m"]

    static func repo(for model: String) -> String {
        model == "en-31m" ? "gradium/phonon-31m-en" : "gradium/phonon-40m-\(model)"
    }

    static func isGated(_ model: String) -> Bool { !model.hasSuffix("-31m") }

    /// Language of a model key ("en-31m" → "en").
    static func language(ofModel model: String) -> String { String(model.prefix(2)) }

    /// Which model speaks a language.
    static func modelKey(language: String, english31m: Bool) -> String {
        language == "en" && english31m ? "en-31m" : language
    }

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

    var installedModels: [String] { Self.models.filter(isModelReady) }
    var installedLanguages: [String] { Self.languages.filter { language in installedModels.contains { Self.language(ofModel: $0) == language } } }

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
            arguments: ["-I", script.path, "--lang", Self.language(ofModel: language), "--models-root", modelsRoot.path,
                        "--size", language.hasSuffix("-31m") ? "31m" : "40m"],
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

    // MARK: Neural Engine (v4.1)

    /// Core ML bundle of a language model (fp16 for the Neural Engine).
    func neuralDirectory(for language: String) -> URL {
        modelDirectory(for: language).appendingPathComponent("coreml", isDirectory: true)
    }

    func isNeuralReady(_ language: String) -> Bool {
        FileManager.default.fileExists(atPath: neuralDirectory(for: language).appendingPathComponent("bundle.json").path)
    }

    /// The bundled exporter (`Contents/MacOS/phonon-coreml-export`).
    var exporterURL: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("phonon-coreml-export")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Converts an installed language model into a Core ML bundle (~200 MB,
    /// about a second) — with the language's voices.
    func prepareNeuralEngine(_ language: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard isModelReady(language) else { throw InstallError.failed(L("Zuerst das Sprachmodell laden.")) }
        guard let exporter = exporterURL else { throw InstallError.failed(L("Core-ML-Export fehlt in dieser App-Version.")) }
        let target = neuralDirectory(for: language)
        let staging = target.deletingLastPathComponent().appendingPathComponent("coreml.partial", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        let status = try await ScriptRunner.run(
            executable: exporter,
            arguments: ["--model", modelDirectory(for: language).path, "--quant", "q8",
                        "--voices", modelDirectory(for: language).appendingPathComponent("voices").path, staging.path],
            environment: ["RUST_LOG": "warn"],
            onLine: onOutput
        )
        guard status == 0, FileManager.default.fileExists(atPath: staging.appendingPathComponent("bundle.json").path) else {
            try? FileManager.default.removeItem(at: staging)
            throw InstallError.failed(status < 0
                ? String(format: L("Core-ML-Export ist abgestürzt (Signal %d)."), -status)
                : L("Core-ML-Export fehlgeschlagen.") + " (\(status))")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
    }

    func removeNeural(_ language: String) throws {
        let dir = neuralDirectory(for: language)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    func removeModel(_ language: String) throws {
        let dir = modelDirectory(for: language)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }
}
