import Foundation

enum AppPaths {
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AudiobookForge", isDirectory: true)
    }

    /// Per-chapter synthesized audio lives here (not in /tmp) so it survives
    /// app restarts for in-app playback review and single-chapter
    /// regeneration without re-synthesizing the whole book. Since the
    /// streaming rework the chapters are stored compressed (AAC/MP3), not
    /// as uncompressed WAVs.
    static var chapterAudioRoot: URL {
        applicationSupportDirectory.appendingPathComponent("chapter_audio", isDirectory: true)
    }

    static func chapterAudioDirectory(bookID: UUID) -> URL {
        let directory = chapterAudioRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Cleans up orphaned temporary files from interrupted runs older than the specified age (default: 1 hour).
    static func cleanupOrphanedTempFiles(olderThan maxAge: TimeInterval = 3600) {
        let tempDir = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-maxAge)
        guard let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("AudiobookForge-chapter-") ||
               name.hasPrefix("AudiobookForge-pauses-") ||
               name.hasPrefix("AudiobookForge-plan-") ||
               name.hasPrefix("ABF-pause-") ||
               name.hasPrefix("abf-audio-") {
                if let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   modDate < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    /// Standalone self-contained runtime directory (Python + static FFmpeg)
    static var runtimeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    static var runtimePythonURL: URL {
        runtimeDirectory.appendingPathComponent("python/bin/python3")
    }

    static var runtimeFFmpegURL: URL {
        runtimeDirectory.appendingPathComponent("bin/ffmpeg")
    }

    static var modelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("models", isDirectory: true)
    }
}
