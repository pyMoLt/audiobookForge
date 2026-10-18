import Foundation

final class GermanKokoroEnvironmentManager: @unchecked Sendable {
    static let shared = GermanKokoroEnvironmentManager()

    static let supportedVoices = ["martin", "victoria", "thorsten"]
    private let baseDirectory = AppPaths.applicationSupportDirectory.appendingPathComponent("models", isDirectory: true)

    private init() {}

    func modelDirectory(for voice: String) -> URL {
        baseDirectory.appendingPathComponent("kokoro-\(voice)", isDirectory: true)
    }

    func voiceURL(for voice: String) -> URL {
        modelDirectory(for: voice).appendingPathComponent("voices/\(voice).safetensors")
    }

    func isVoiceReady(_ voice: String) -> Bool {
        guard Self.supportedVoices.contains(voice) else { return false }
        let dir = modelDirectory(for: voice)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            && FileManager.default.fileExists(atPath: voiceURL(for: voice).path)
    }

    func install(_ voice: String, onOutput: @escaping @Sendable (String) -> Void) async throws {
        guard Self.supportedVoices.contains(voice) else {
            throw TTSEngineError.notReady("Unbekannte deutsche Kokoro-Stimme: \(voice)")
        }
        let bridge = BridgeEnvironmentManager.shared
        guard bridge.isEnvironmentReady() else {
            throw TTSEngineError.notReady("Kokoro-MLX-Umgebung zuerst unter Diagnose einrichten.")
        }
        guard let script = Bundle.main.url(forResource: "setup_german_kokoro", withExtension: "py", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "setup_german_kokoro", withExtension: "py") else {
            throw BridgeEnvironmentError.resourcesMissing
        }

        let process = Process()
        process.executableURL = bridge.pythonExecutableURL
        process.arguments = [script.path, "--voice", voice, "--output", modelDirectory(for: voice).path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lastOutput = LockedBox("")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                lastOutput.withLock { $0 += text }
                text.split(separator: "\n", omittingEmptySubsequences: true).forEach { onOutput(String($0)) }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TTSEngineError.processFailed(lastOutput.withLock { $0.suffix(500).description }))
                }
            }
            do { try process.run() }
            catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
