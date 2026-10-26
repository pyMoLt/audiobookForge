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
    /// Pure path computation — does not create directories as a side effect.
    static func chapterFileURL(bookID: UUID, order: Int, format: OutputFormat, root: URL = AppPaths.chapterAudioRoot) -> URL {
        let directory = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        return directory.appendingPathComponent("\(String(format: "%03d", order)).\(ChapterAudioEncoder.fileExtension(for: format))")
    }

    /// Prepares the book's chapter audio directory on disk when files are about to be written.
    @discardableResult
    static func prepareChapterAudioDirectory(bookID: UUID, root: URL = AppPaths.chapterAudioRoot) throws -> URL {
        let directory = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Removes a book's whole chapter audio directory. Called when the user
    /// removes the book from the library — the audio was only ever an
    /// intermediate, the finished audiobook lives in the output folder.
    static func removeChapterAudio(bookID: UUID, root: URL = AppPaths.chapterAudioRoot) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(bookID.uuidString, isDirectory: true))
    }

    /// Total size of a book's chapter audio directory (0 when absent) —
    /// used to report the disk space freed by the post-packaging cleanup.
    static func chapterAudioSizeBytes(bookID: UUID, root: URL = AppPaths.chapterAudioRoot) -> Int64 {
        directorySizeBytes(root.appendingPathComponent(bookID.uuidString, isDirectory: true))
    }

    private static func directorySizeBytes(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Restores every chapter's audio file from the verified packaged
    /// single-file output (M4B/M4A) in ONE lossless ffmpeg pass (plan 5.2):
    /// `ffmpeg -i book.m4b -f segment -segment_times t1,t2,… -c copy -map 0:a`
    /// — one process instead of one cut per chapter. Used before a single
    /// chapter is re-synthesized after the intermediate chapter audio was
    /// deleted.
    ///
    /// Returns the book with every chapter's `audioFileURL` pointing at
    /// the restored file (durations re-measured). Throws when the packaged
    /// file is missing/unreadable or the segment cut doesn't produce one
    /// file per chapter.
    static func restoreChapterAudio(
        fromPackagedURL packagedURL: URL,
        book: BookProject,
        ffmpeg: URL,
        root: URL = AppPaths.chapterAudioRoot
    ) async throws -> BookProject {
        var book = book
        let sorted = book.sortedChapters
        guard !sorted.isEmpty,
              FileManager.default.isReadableFile(atPath: packagedURL.path) else {
            throw PackagerError.noChapterAudio
        }

        let bookID = book.id
        // Segment boundaries = the chapters' cumulative start seconds
        // (everything after the first start; a segment starts per time).
        let boundaries = sorted.dropFirst().compactMap(\.audioStartSeconds)
        let times = boundaries.map { String(format: "%.3f", $0) }.joined(separator: ",")

        let staging = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent("restore-tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let segmentPattern = staging.appendingPathComponent("%04d.m4a").path
        try await FFmpegRunner.run(
            executable: ffmpeg,
            arguments: [
                "-y", "-hide_banner", "-loglevel", "error",
                "-i", packagedURL.path,
                "-f", "segment",
                "-segment_times", times,
                "-c", "copy",
                "-map", "0:a",
                segmentPattern,
            ]
        )

        let files = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard files.count == sorted.count else {
            throw PackagerError.ffmpegFailed("Segment-Schnitt erzeugte \(files.count) Dateien statt \(sorted.count).")
        }

        try prepareChapterAudioDirectory(bookID: bookID, root: root)

        for (index, chapter) in sorted.enumerated() {
            let destination = chapterFileURL(bookID: bookID, order: chapter.order, format: book.outputFormat, root: root)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: files[index], to: destination)
            guard let bookIndex = book.chapters.firstIndex(where: { $0.id == chapter.id }) else { continue }
            book.chapters[bookIndex].audioFileURL = destination
            book.chapters[bookIndex].audioStatus = .ready
            // Keep the known duration/start offsets: fresh measurements on
            // the cut files drift by up to two AAC frames of priming
            // metadata (≈ 85 ms at 24 kHz), which would shift every
            // chapter mark of the re-packaged M4B. The stored values are
            // the ones the verified M4B was built from.
        }
        return book
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
        guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settings) else { throw PackagerError.ffmpegNotFound }
        var arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path]
        switch destination.pathExtension.lowercased() {
        case "m4a":
            arguments += ["-c:a", "aac", "-b:a", "\(max(16, settings.aacBitrateKbps))k", "-f", "ipod", destination.path]
        case "mp3":
            arguments += ["-c:a", "libmp3lame", "-qscale:a", String(settings.mp3Quality), destination.path]
        default:
            throw ChapterAudioEncoder.EncoderError.unsupportedOutput(destination.pathExtension)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FFmpegRunner.run(executable: ffmpeg, arguments: arguments)
    }
}
