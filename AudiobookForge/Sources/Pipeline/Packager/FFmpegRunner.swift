import Foundation

enum FFmpegLocator {
    /// Cached result of the `which ffmpeg` fallback so the fallback
    /// subprocess runs at most once per app launch.
    private static let whichCache = LockedBox<URL?>(nil)

    static func resolve(settings: AppSettings) -> URL? {
        let override = settings.dependencyPathOverrides.ffmpegPath.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        if FileManager.default.isExecutableFile(atPath: AppPaths.runtimeFFmpegURL.path) {
            return AppPaths.runtimeFFmpegURL
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

    /// Async variant for call sites that are already async: the `which`
    /// fallback runs through `ProcessRunner` (no cooperative-pool thread
    /// parked) and its result is cached for the sync variant too.
    static func resolveAsync(settings: AppSettings) async -> URL? {
        let override = settings.dependencyPathOverrides.ffmpegPath.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        if FileManager.default.isExecutableFile(atPath: AppPaths.runtimeFFmpegURL.path) {
            return AppPaths.runtimeFFmpegURL
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        if let cached = whichCache.withLock({ $0 }) { return cached }
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["ffmpeg"]
        ), result.terminationStatus == 0 else { return nil }
        let path = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        whichCache.withLock { $0 = url }
        return url
    }

    private static func whichFFmpeg() -> URL? {
        if let cached = whichCache.withLock({ $0 }) { return cached }
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
            let url = URL(fileURLWithPath: path)
            whichCache.withLock { $0 = url }
            return url
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
