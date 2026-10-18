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
}
