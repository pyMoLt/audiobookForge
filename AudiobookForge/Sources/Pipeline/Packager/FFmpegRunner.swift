import Foundation

enum FFmpegLocator {
    static func resolve(settings: AppSettings) -> URL? {
        let override = settings.dependencyPathOverrides.ffmpegPath.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return whichFFmpeg()
    }

    private static func whichFFmpeg() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }
}

enum FFmpegRunner {
    static func run(executable: URL, arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lastLines = LockedBox<[String]>([])
        let cancelled = LockedBox(false)
        let processBox = LockedBox(process)

        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    lastLines.withLock { lines in
                        lines.append(String(line))
                        if lines.count > 20 { lines.removeFirst() }
                    }
                    onOutput?(String(line))
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if cancelled.withLock({ $0 }) {
                    continuation.resume(throwing: CancellationError())
                } else if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let joined = lastLines.withLock { $0.joined(separator: "\n") }
                    continuation.resume(throwing: PackagerError.ffmpegFailed(joined))
                }
            }

            do {
                try process.run()
                if cancelled.withLock({ $0 }) { process.terminate() }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
          }
        } onCancel: {
            cancelled.withLock { $0 = true }
            processBox.withLock { if $0.isRunning { $0.terminate() } }
        }
    }
}
