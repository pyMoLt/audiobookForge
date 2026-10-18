import Foundation

/// Owns the per-book chapter audio files in Application Support. Chapters
/// are stored compressed (AAC or MP3, matching the book's output format)
/// — they are the small on-disk basis for the in-app player,
/// single-chapter regeneration and packaging. Uncompressed WAVs are a
/// legacy of the old pipeline and are migrated away once, then never
/// created again.
///
/// Every entry point takes an optional `root` (defaulting to the app's
/// real chapter audio directory) so tests can run against an isolated
/// temporary directory instead of the developer's real library.
enum ChapterAudioStore {
    /// Compressed chapter file for a chapter's order index, matching the
    /// book's output format (see `ChapterAudioEncoder.fileExtension`).
    static func chapterFileURL(bookID: UUID, order: Int, format: OutputFormat, root: URL = AppPaths.chapterAudioRoot) -> URL {
        let directory = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(String(format: "%03d", order)).\(ChapterAudioEncoder.fileExtension(for: format))")
    }

    /// Removes a book's whole chapter audio directory. Called when the user
    /// removes the book from the library — the audio was only ever an
    /// intermediate, the finished audiobook lives in the output folder.
    static func removeChapterAudio(bookID: UUID, root: URL = AppPaths.chapterAudioRoot) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(bookID.uuidString, isDirectory: true))
    }

    /// Deletes chapter audio directories whose book no longer exists in
    /// the library (leftovers from before removal cleaned up after itself,
    /// or from a wiped library.json). Returns the number of orphaned
    /// directories removed.
    @discardableResult
    static func removeOrphanChapterAudio(keeping bookIDs: [UUID], root: URL = AppPaths.chapterAudioRoot) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        let keep = Set(bookIDs)
        var removed = 0
        for entry in contents where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            if !keep.contains(id) {
                try? FileManager.default.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }

    /// One-time migration of the old pipeline's uncompressed chapter WAVs:
    /// each is transcoded to the book's compressed chapter format and the
    /// WAV is deleted. Books are updated in place (audioFileURL,
    /// audioDurationSeconds) via the library store.
    static func migrateLegacyChapterAudio(libraryStore: LibraryStore, settings: AppSettings, root: URL = AppPaths.chapterAudioRoot) async {
        let books = libraryStore.books
        for var book in books {
            guard book.chapters.contains(where: { $0.audioFileURL?.pathExtension.lowercased() == "wav" }) else { continue }

            let bookID = book.id
            let format = book.outputFormat
            var changed = false
            for index in book.chapters.indices {
                guard let wavURL = book.chapters[index].audioFileURL,
                      wavURL.pathExtension.lowercased() == "wav",
                      FileManager.default.fileExists(atPath: wavURL.path) else { continue }

                let destination = chapterFileURL(bookID: bookID, order: book.chapters[index].order, format: format, root: root)
                do {
                    try await transcode(source: wavURL, destination: destination, settings: settings)
                    try FileManager.default.removeItem(at: wavURL)
                    book.chapters[index].audioFileURL = destination
                    if let duration = try? await WaveFileInspector.durationSeconds(url: destination) {
                        book.chapters[index].audioDurationSeconds = duration
                    }
                    changed = true
                } catch {
                    // Keep the WAV — better than losing the chapter audio.
                    continue
                }
            }
            if changed {
                libraryStore.upsert(book)
            }
        }
    }

    /// Compressed-domain re-encode of an existing audio file (no loudness
    /// pass — legacy WAVs were already normalized by the old pipeline).
    private static func transcode(source: URL, destination: URL, settings: AppSettings) async throws {
        guard let ffmpeg = FFmpegLocator.resolve(settings: settings) else { throw PackagerError.ffmpegNotFound }
        var arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path]
        switch destination.pathExtension.lowercased() {
        case "m4a":
            arguments += ["-c:a", "aac", "-b:a", "\(max(16, settings.chapterAudioBitrateKbps))k", "-f", "ipod", destination.path]
        case "mp3":
            arguments += ["-c:a", "libmp3lame", "-qscale:a", String(settings.mp3Quality), destination.path]
        default:
            throw ChapterAudioEncoder.EncoderError.unsupportedOutput(destination.pathExtension)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FFmpegRunner.run(executable: ffmpeg, arguments: arguments)
    }
}
