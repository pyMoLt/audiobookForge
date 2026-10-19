import Foundation

/// One-time offer for books that were packaged under v2 (plan 5.2):
/// their finished M4B/M4A exists and is intact, but the intermediate
/// chapter audio is still on disk (~0.9 GB for a big textbook). The
/// dialog lists the candidates with their savings and deletes ONLY after
/// explicit user confirmation — never automatically. Each book is
/// verified (ffprobe) immediately before its chapter audio is deleted.
enum ChapterAudioMigrationOffer {
    struct Candidate: Identifiable, Sendable {
        let bookID: UUID
        let title: String
        let packagedURL: URL
        let savingsBytes: Int64
        var id: UUID { bookID }
    }

    static let offerShownDefaultsKey = "ABFChapterAudioOfferShown"

    static func candidates(from books: [BookProject], chapterAudioRoot: URL) -> [Candidate] {
        books.compactMap { book -> Candidate? in
            guard book.status == .completed,
                  book.outputFormat != .mp3Chapters,
                  book.packagedAudio == nil,
                  let packagedURL = packagedOutputURL(for: book) else { return nil }
            let savings = ChapterAudioStore.chapterAudioSizeBytes(bookID: book.id, root: chapterAudioRoot)
            guard savings > 0 else { return nil }
            return Candidate(
                bookID: book.id,
                title: book.title,
                packagedURL: packagedURL,
                savingsBytes: savings
            )
        }
    }

    /// Looks for the packaged output next to the book's output directory
    /// (named like the packager names it).
    static func packagedOutputURL(for book: BookProject) -> URL? {
        guard let directory = book.outputDirectoryURL else { return nil }
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = book.title.components(separatedBy: invalid).joined(separator: "-")
        let fileName = cleaned.isEmpty ? "Audiobook" : cleaned
        let url = directory.appendingPathComponent("\(fileName).\(book.outputFormat.fileExtension)")
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Deletes each candidate's chapter audio after verifying its
    /// packaged output; records `packagedAudio` and cumulative
    /// `audioStartSeconds` so the player streams from the M4B.
    /// Returns German status lines for a follow-up dialog/log.
    static func release(
        _ candidates: [Candidate],
        libraryStore: LibraryStore,
        ffmpeg: URL,
        chapterAudioRoot: URL
    ) async -> [String] {
        var lines: [String] = []
        for candidate in candidates {
            guard var book = libraryStore.book(id: candidate.bookID) else { continue }
            let files = book.sortedChapters.compactMap { chapter -> ChapterAudioFile? in
                guard let url = chapter.audioFileURL,
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return ChapterAudioFile(chapter: chapter, url: url)
            }
            guard !files.isEmpty else {
                lines.append("\(book.title): keine Kapiteldateien gefunden — übersprungen.")
                continue
            }
            let result = await ChapterAudioCleanup.finalizeSingleFile(
                book: book,
                packagedURL: candidate.packagedURL,
                chapterAudioFiles: files,
                ffmpeg: ffmpeg,
                keepChapterAudio: false,
                chapterAudioRoot: chapterAudioRoot
            )
            book = result.book
            libraryStore.upsert(book)
            if result.verified {
                lines.append("\(book.title): \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)) freigegeben.")
            } else {
                lines.append("\(book.title): Verifikation fehlgeschlagen — nichts gelöscht.")
            }
        }
        return lines
    }
}
