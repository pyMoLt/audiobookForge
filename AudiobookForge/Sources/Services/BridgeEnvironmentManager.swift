import Foundation

/// Manages the Python side-car environment used to run Kokoro TTS via
/// mlx-audio. The bridge script + setup script ship as app resources and get
/// copied into Application Support on first use, where a dedicated venv is
/// created so the app never touches the user's system Python.
final class BridgeEnvironmentManager: @unchecked Sendable {
    static let shared = BridgeEnvironmentManager()

    let bridgeDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        bridgeDirectory = appSupport.appendingPathComponent("AudiobookForge/bridge", isDirectory: true)
    }

    var pythonExecutableURL: URL {
        bridgeDirectory.appendingPathComponent(".venv/bin/python")
    }

    var bridgeScriptURL: URL {
        bridgeDirectory.appendingPathComponent("kokoro_bridge.py")
    }

    private var setupScriptURL: URL {
        bridgeDirectory.appendingPathComponent("setup_bridge_env.sh")
    }

    func isEnvironmentReady() -> Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutableURL.path)
            && FileManager.default.fileExists(atPath: bridgeScriptURL.path)
    }

    /// Copies the bundled bridge script + setup script into Application
    /// Support if missing or older than the bundled copies. Cheap, safe to
    /// call often.
    func ensureResourcesCopied() throws {
        try FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)

        guard let bundledScript = Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "kokoro_bridge", withExtension: "py"),
            let bundledSetup = Bundle.main.url(forResource: "setup_bridge_env", withExtension: "sh", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "setup_bridge_env", withExtension: "sh")
        else {
            throw BridgeEnvironmentError.resourcesMissing
        }

        try copyIfNeeded(from: bundledScript, to: bridgeScriptURL)
        try copyIfNeeded(from: bundledSetup, to: setupScriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeScriptURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setupScriptURL.path)
    }

    private func copyIfNeeded(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let sourceData = try Data(contentsOf: source)
            let destData = try? Data(contentsOf: destination)
            if sourceData == destData { return }
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// Runs the setup script, streaming raw stdout lines to `onOutput` as
    /// they arrive. Long-running (model download on first run).
    func runSetup(onOutput: @escaping @Sendable (String) -> Void) async throws {
        try ensureResourcesCopied()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [setupScriptURL.path, bridgeDirectory.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                text.split(separator: "\n", omittingEmptySubsequences: true).forEach {
                    onOutput(String($0))
                }
            }

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BridgeEnvironmentError.setupFailed(exitCode: proc.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

enum BridgeEnvironmentError: LocalizedError {
    case resourcesMissing
    case setupFailed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            return "Bridge-Ressourcen (kokoro_bridge.py / setup_bridge_env.sh) wurden nicht im App-Bundle gefunden."
        case .setupFailed(let code):
            return "Setup-Skript ist mit Exit-Code \(code) fehlgeschlagen."
        }
    }
}
