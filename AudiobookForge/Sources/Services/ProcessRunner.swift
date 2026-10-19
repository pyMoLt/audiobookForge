import Foundation

/// Result of a finished subprocess.
struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var standardErrorText: String {
        String(data: standardError, encoding: .utf8) ?? ""
    }

    var standardOutputText: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }
}

/// Async replacement for `Process.waitUntilExit()`: that call parks a
/// thread of Swift's cooperative pool, and with several TTS workers,
/// ffmpeg encoders and bridge processes running, the pool used to starve
/// (app looked wedged). `ProcessRunner` instead parks no thread at all —
/// it registers a `terminationHandler`, streams stdout/stderr through
/// `readabilityHandler`s, and only resumes the awaiting task when the
/// process has fully exited.
///
/// Cancellation sends SIGTERM (and SIGKILL after 2 s if the process
/// ignores it), then throws `CancellationError`.
enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = LockedBox<Data>(Data())
        let stderr = LockedBox<Data>(Data())
        let cancelled = LockedBox(false)

        func stream(_ pipe: Pipe, into box: LockedBox<Data>) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    box.withLock { $0.append(data) }
                }
            }
        }
        stream(stdoutPipe, into: stdout)
        stream(stderrPipe, into: stderr)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { _ in
                    // The child is gone; nothing else holds the write ends,
                    // so draining what is still buffered cannot block.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let restErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !restOut.isEmpty { stdout.withLock { $0.append(restOut) } }
                    if !restErr.isEmpty { stderr.withLock { $0.append(restErr) } }
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: ProcessResult(
                            terminationStatus: process.terminationStatus,
                            standardOutput: stdout.withLock { $0 },
                            standardError: stderr.withLock { $0 }
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                Task.detached {
                    try? await Task.sleep(for: .seconds(2))
                    kill(pid, SIGKILL)
                }
            }
        }
    }
}
