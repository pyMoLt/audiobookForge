import Foundation

/// Post-packaging step (plan 5.2): after a book has been packaged, the
/// intermediate chapter audio can be deleted from disk — but only after
/// the output has been verified. Playback then runs from the packaged
/// file (`PackagedAudioInfo` + `Chapter.audioStartSeconds`).
///
/// Deleting saves disk space (≈ 29 MB per audio hour, ≈ 0.9 GB for a big
/// textbook) — it does not save RAM or SSD write cycles already spent.
enum ChapterAudioCleanup {
    struct Result {
        var book: BookProject
        var verified: Bool
        var freedBytes: Int64
        var messages: [String]
    }

    /// Single-file outputs (M4B/M4A): verify, record `packagedAudio` and
    /// cumulative `audioStartSeconds`, then delete the chapter audio
    /// (unless `keepChapterAudio` is set).
    static func finalizeSingleFile(
        book: BookProject,
        packagedURL: URL,
        chapterAudioFiles: [ChapterAudioFile],
        ffmpeg: URL,
        keepChapterAudio: Bool,
        chapterAudioRoot: URL
    ) async -> Result {
        var book = book
        var messages: [String] = []
        let ordered = chapterAudioFiles.sorted { $0.chapter.order < $1.chapter.order }

        // Cumulative chapter starts from the SAME duration source the
        // packager used for its chapter marks (the chapters' stored
        // durations) — mixing sources would shift the seek offsets
        // against the marks. Files without a known duration (legacy)
        // fall back to a measurement.
        var durations: [Double] = []
        var starts: [Double] = []
        var cursor = 0.0
        for item in ordered {
            let duration: Double
            if let known = item.chapter.audioDurationSeconds {
                duration = known
            } else {
                duration = (try? await WaveFileInspector.durationSeconds(url: item.url)) ?? 0
            }
            durations.append(duration)
            starts.append(cursor)
            cursor += duration
        }
        let startsByChapterID = Dictionary(zip(ordered.map(\.chapter.id), starts), uniquingKeysWith: { first, _ in first })
        for index in book.chapters.indices {
            book.chapters[index].audioStartSeconds = startsByChapterID[book.chapters[index].id]
        }

        let verification = await PackagedAudioVerifier.verifySingleFileOutput(
            url: packagedURL,
            ffmpeg: ffmpeg,
            chapterDurations: durations
        )
        guard verification.isVerified else {
            messages.append("Verifikation der Ausgabe fehlgeschlagen — Kapitel-Audio wird NICHT gelöscht:")
            messages.append(contentsOf: verification.problems.map { "  \($0)" })
            return Result(book: book, verified: false, freedBytes: 0, messages: messages)
        }

        let sizeBytes = ((try? FileManager.default.attributesOfItem(atPath: packagedURL.path))?[.size] as? Int64) ?? 0
        let bookmarkData = (try? packagedURL.bookmarkData()) ?? Data()
        book.packagedAudio = PackagedAudioInfo(
            url: packagedURL,
            bookmarkData: bookmarkData,
            sizeBytes: sizeBytes,
            verifiedAt: Date()
        )

        if keepChapterAudio {
            messages.append("Ausgabe verifiziert. Kapitel-Audio bleibt erhalten (Einstellung „Kapitel-Audio nach dem Verpacken behalten“).")
            return Result(book: book, verified: true, freedBytes: 0, messages: messages)
        }

        let freed = ChapterAudioStore.chapterAudioSizeBytes(bookID: book.id, root: chapterAudioRoot)
        for index in book.chapters.indices {
            book.chapters[index].audioFileURL = nil
            // audioStatus stays .ready — playback runs from the packaged file.
        }
        ChapterAudioStore.removeChapterAudio(bookID: book.id, root: chapterAudioRoot)
        messages.append("Ausgabe verifiziert. Kapitel-Audio gelöscht — \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freigegeben. Wiedergabe läuft aus \(packagedURL.lastPathComponent).")
        return Result(book: book, verified: true, freedBytes: freed, messages: messages)
    }

    /// MP3 chapter output: the exported per-chapter files in the output
    /// folder ARE the playback source, so `chapter_audio/` is redundant
    /// once they are verified. The chapter `audioFileURL`s are repointed
    /// at the exported files.
    ///
    /// Note on "verschieben statt kopieren": the export writes ID3
    /// metadata (title/track/album), which a plain `move` could not do —
    /// so the export stays a stream copy and only the *intermediate*
    /// `chapter_audio/` directory is removed afterwards.
    static func finalizeMP3Chapters(
        book: BookProject,
        outputDirectory: URL,
        chapterAudioFiles: [ChapterAudioFile],
        keepChapterAudio: Bool,
        chapterAudioRoot: URL
    ) async -> Result {
        var book = book
        var messages: [String] = []
        let ordered = chapterAudioFiles.sorted { $0.chapter.order < $1.chapter.order }

        var allVerified = !ordered.isEmpty
        for (fileIndex, item) in ordered.enumerated() {
            let expected = (try? await WaveFileInspector.durationSeconds(url: item.url)) ?? 0
            let fileName = String(format: "%02d - %@.mp3", fileIndex + 1, sanitize(item.chapter.title))
            let exported = outputDirectory.appendingPathComponent(fileName)
            let readable = FileManager.default.isReadableFile(atPath: exported.path)
            let durationOK = await PackagedAudioVerifier.verifyChapterFile(url: exported, expectedDurationSeconds: expected)
            if !(readable && durationOK) {
                allVerified = false
                messages.append("Exportierte Kapiteldatei nicht verifiziert: \(exported.lastPathComponent)")
            }
        }
        guard allVerified else {
            messages.insert("Verifikation der MP3-Kapiteldateien fehlgeschlagen — Kapitel-Audio wird NICHT gelöscht.", at: 0)
            return Result(book: book, verified: false, freedBytes: 0, messages: messages)
        }

        if keepChapterAudio {
            messages.append("MP3-Kapiteldateien verifiziert. Kapitel-Audio bleibt erhalten (Einstellung „Kapitel-Audio nach dem Verpacken behalten“).")
            return Result(book: book, verified: true, freedBytes: 0, messages: messages)
        }

        let freed = ChapterAudioStore.chapterAudioSizeBytes(bookID: book.id, root: chapterAudioRoot)
        for (fileIndex, item) in ordered.enumerated() {
            let fileName = String(format: "%02d - %@.mp3", fileIndex + 1, sanitize(item.chapter.title))
            let exported = outputDirectory.appendingPathComponent(fileName)
            guard let index = book.chapters.firstIndex(where: { $0.id == item.chapter.id }) else { continue }
            book.chapters[index].audioFileURL = exported
        }
        ChapterAudioStore.removeChapterAudio(bookID: book.id, root: chapterAudioRoot)
        messages.append("MP3-Kapiteldateien verifiziert. Zwischenspeicher gelöscht — \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freigegeben. Wiedergabe läuft aus den exportierten Dateien.")
        return Result(book: book, verified: true, freedBytes: freed, messages: messages)
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    /// Scans completed single-file books (M4B/M4A): if their packaged file exists on disk
    /// and is verified, releases the intermediate chapter audio so disk space is freed automatically.
    static func cleanupVerifiedPackagedBooks(
        libraryStore: LibraryStore,
        ffmpeg: URL,
        chapterAudioRoot: URL
    ) async {
        let candidates = libraryStore.books.filter {
            $0.status == .completed && $0.outputFormat != .mp3Chapters
        }
        for book in candidates {
            let savings = ChapterAudioStore.chapterAudioSizeBytes(bookID: book.id, root: chapterAudioRoot)
            guard savings > 0 else { continue }
            guard let packagedURL = book.packagedAudio?.url ?? ChapterAudioMigrationOffer.packagedOutputURL(for: book) else { continue }

            let files: [ChapterAudioFile] = book.chapters.compactMap { ch in
                if let url = ch.audioFileURL, FileManager.default.fileExists(atPath: url.path) {
                    return ChapterAudioFile(chapter: ch, url: url)
                }
                let fallback = ChapterAudioStore.chapterFileURL(bookID: book.id, order: ch.order, format: book.outputFormat, root: chapterAudioRoot)
                if FileManager.default.fileExists(atPath: fallback.path) {
                    return ChapterAudioFile(chapter: ch, url: fallback)
                }
                return nil
            }
            guard files.count == book.chapters.count else { continue }

            let result = await finalizeSingleFile(
                book: book,
                packagedURL: packagedURL,
                chapterAudioFiles: files,
                ffmpeg: ffmpeg,
                keepChapterAudio: false,
                chapterAudioRoot: chapterAudioRoot
            )
            if result.verified {
                await MainActor.run {
                    libraryStore.upsert(result.book)
                }
            }
        }
    }
}
