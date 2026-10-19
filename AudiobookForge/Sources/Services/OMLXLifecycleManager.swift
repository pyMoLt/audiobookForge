import Foundation

/// Controls the lifecycle of the local oMLX background server (starting and stopping it via omlx CLI)
/// to allow optional auto-starting when needed and auto-unloading to free 20+ GB unified memory before TTS synthesis.
enum OMLXLifecycleManager {
    static var cliURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/omlx",
            "/usr/local/bin/omlx",
            "/Applications/oMLX.app/Contents/MacOS/omlx-cli"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static var isCLIAvailable: Bool { cliURL != nil }

    /// Starts the background oMLX server using `omlx start --timeout <seconds>`.
    static func startServer(timeout: TimeInterval = 45) async -> Bool {
        guard let cli = cliURL else { return false }
        guard let result = try? await ProcessRunner.run(executable: cli, arguments: ["start", "--timeout", String(Int(timeout))]) else {
            return false
        }
        return result.terminationStatus == 0
    }

    /// Stops the background oMLX server using `omlx stop --timeout <seconds>`,
    /// freeing all unified memory held by loaded models.
    static func stopServer(timeout: TimeInterval = 15) async -> Bool {
        guard let cli = cliURL else { return false }
        guard let result = try? await ProcessRunner.run(executable: cli, arguments: ["stop", "--timeout", String(Int(timeout))]) else {
            return false
        }
        return result.terminationStatus == 0
    }
}
