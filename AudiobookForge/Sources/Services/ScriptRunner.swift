import Foundation

/// Runs a setup/download script and streams its output line by line (v4:
/// engine installs and model downloads, which need an environment such as
/// HF_TOKEN). Cancellation terminates the script.
enum ScriptRunner {
    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LockedBox("")

        @Sendable func flush(_ text: String, final: Bool) {
            let lines: [String] = buffer.withLock { pending in
                pending += text
                var out: [String] = []
                while let range = pending.range(of: "\n") {
                    out.append(String(pending[..<range.lowerBound]))
                    pending.removeSubrange(..<range.upperBound)
                }
                if final, !pending.isEmpty { out.append(pending); pending = "" }
                return out
            }
            lines.map { $0.replacingOccurrences(of: "\r", with: "") }.filter { !$0.isEmpty }.forEach(onLine)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil; return }
                    flush(String(decoding: data, as: UTF8.self), final: false)
                }
                process.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                    flush(String(decoding: rest, as: UTF8.self), final: true)
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        // A crash (signal) comes back negative, so it cannot be
                        // mistaken for the program's own exit code (v4.2.2).
                        continuation.resume(returning: proc.terminationReason == .uncaughtSignal ? -proc.terminationStatus : proc.terminationStatus)
                    }
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
