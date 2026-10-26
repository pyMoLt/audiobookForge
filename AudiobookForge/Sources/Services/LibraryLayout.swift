import Foundation
import AppKit

/// On-disk layout of the v3 library (plan 5.1). The library is split per
/// book so that startup only reads a small index plus per-book metadata,
/// and saving touches only the book that actually changed — instead of
/// re-encoding the whole 54 MB `library.json` on every chapter status
/// change.
///
/// Layout under the app-support root:
/// ```
/// library/
///   index.json                 # schemaVersion + list of book entries
///   books/<bookID>/
///     book.json                # BookProject metadata, chapter metadata (no text)
///     text/source.json         # sourceChapters (full Chapter payloads)
///     text/raw.json            # rawImportedChapters
///     text/chapters.json       # per-chapter narration texts (deduplicated)
///     cover.jpg  cover_thumb.jpg
/// ```
///
/// Chapter texts are deduplicated on write: `rawText` is only stored when
/// it differs from `cleanedText` (the decoder restores
/// `rawText = cleanedText` when absent), and identical
/// `sourceChapters`/`rawImportedChapters` are stored once — the other side
/// just references the same file (`sourceChaptersSameAsRaw`).
enum LibraryLayout {
    static let schemaVersion = 3

    // MARK: - Paths

    static func libraryRoot(_ root: URL) -> URL {
        root.appendingPathComponent("library", isDirectory: true)
    }

    static func indexURL(_ root: URL) -> URL {
        libraryRoot(root).appendingPathComponent("index.json")
    }

    static func booksRoot(_ root: URL) -> URL {
        libraryRoot(root).appendingPathComponent("books", isDirectory: true)
    }

    static func bookDirectory(_ root: URL, bookID: UUID) -> URL {
        booksRoot(root).appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func bookMetadataURL(_ root: URL, bookID: UUID) -> URL {
        bookDirectory(root, bookID: bookID).appendingPathComponent("book.json")
    }

    static func textDirectory(_ root: URL, bookID: UUID) -> URL {
        bookDirectory(root, bookID: bookID).appendingPathComponent("text", isDirectory: true)
    }

    static func chapterTextsURL(_ root: URL, bookID: UUID) -> URL {
        textDirectory(root, bookID: bookID).appendingPathComponent("chapters.json")
    }

    static func sourceChaptersURL(_ root: URL, bookID: UUID) -> URL {
        textDirectory(root, bookID: bookID).appendingPathComponent("source.json")
    }

    static func rawChaptersURL(_ root: URL, bookID: UUID) -> URL {
        textDirectory(root, bookID: bookID).appendingPathComponent("raw.json")
    }

    static func coverURL(_ root: URL, bookID: UUID) -> URL {
        bookDirectory(root, bookID: bookID).appendingPathComponent("cover.jpg")
    }

    static func coverThumbURL(_ root: URL, bookID: UUID) -> URL {
        bookDirectory(root, bookID: bookID).appendingPathComponent("cover_thumb.jpg")
    }

    static func legacyLibraryURL(_ root: URL) -> URL {
        root.appendingPathComponent("library.json")
    }

    static func legacyBackupURL(_ root: URL) -> URL {
        root.appendingPathComponent("library.json.v2.bak")
    }

    static func hasV3Index(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: indexURL(root).path)
    }

    // MARK: - Index

    struct IndexEntry: Codable {
        var id: UUID
        var title: String
        var author: String
        var status: BookProjectStatus
        var mode: ProcessingMode
        var documentType: DocumentType
        var topic: String?
        var folderID: UUID?
        var createdAt: Date
        /// Path of the sidebar thumbnail (relative to the app-support root).
        var coverThumbPath: String?
        var chapterCount: Int
        var durationSeconds: Double?
    }

    struct LibraryIndex: Codable {
        var schemaVersion: Int
        var books: [IndexEntry]
    }

    static func indexEntry(for book: BookProject, root: URL) -> IndexEntry {
        IndexEntry(
            id: book.id,
            title: book.title,
            author: book.author,
            status: book.status,
            mode: book.mode,
            documentType: book.documentType,
            topic: book.topic,
            folderID: book.folderID,
            createdAt: book.createdAt,
            coverThumbPath: FileManager.default.fileExists(atPath: coverThumbURL(root, bookID: book.id).path)
                ? "library/books/\(book.id.uuidString)/cover_thumb.jpg" : nil,
            chapterCount: book.chapters.count,
            durationSeconds: {
                let seconds = book.chapters.compactMap(\.audioDurationSeconds).reduce(0, +)
                return seconds > 0 ? seconds : nil
            }()
        )
    }

    static func encodeIndex(_ index: LibraryIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(index)
    }

    static func decodeIndex(_ data: Data) throws -> LibraryIndex {
        try JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    // MARK: - Metadata (book.json)

    /// Chapter metadata as stored in `book.json` — everything except the
    /// narration texts, which live in `text/chapters.json`.
    struct ChapterMetadata: Codable {
        var id: UUID
        var title: String
        var groupTitle: String?
        var order: Int
        var audioStatus: ChapterAudioStatus
        var audioFileURL: URL?
        var audioDurationSeconds: Double?
        var audioStartSeconds: Double?
        var audioSegments: [TTSSegment]?
        var lastError: String?
        var matterKind: ChapterMatterKind?
        var includeInNarration: Bool?

        init(chapter: Chapter) {
            id = chapter.id
            title = chapter.title
            groupTitle = chapter.groupTitle
            order = chapter.order
            audioStatus = chapter.audioStatus
            audioFileURL = chapter.audioFileURL
            audioDurationSeconds = chapter.audioDurationSeconds
            audioStartSeconds = chapter.audioStartSeconds
            audioSegments = chapter.audioSegments
            lastError = chapter.lastError
            matterKind = chapter.matterKind
            includeInNarration = chapter.includeInNarration
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            groupTitle = try c.decodeIfPresent(String.self, forKey: .groupTitle)
            order = try c.decode(Int.self, forKey: .order)
            audioStatus = try c.decodeIfPresent(ChapterAudioStatus.self, forKey: .audioStatus) ?? .pending
            audioFileURL = try c.decodeIfPresent(URL.self, forKey: .audioFileURL)
            audioDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .audioDurationSeconds)
            audioStartSeconds = try c.decodeIfPresent(Double.self, forKey: .audioStartSeconds)
            audioSegments = try c.decodeIfPresent([TTSSegment].self, forKey: .audioSegments)
            lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
            matterKind = try c.decodeIfPresent(ChapterMatterKind.self, forKey: .matterKind)
            includeInNarration = try c.decodeIfPresent(Bool.self, forKey: .includeInNarration)
        }

        var chapter: Chapter {
            var chapter = Chapter(title: title, rawText: "", cleanedText: "", order: order)
            chapter.id = id
            chapter.groupTitle = groupTitle
            chapter.audioStatus = audioStatus
            chapter.audioFileURL = audioFileURL
            chapter.audioDurationSeconds = audioDurationSeconds
            chapter.audioStartSeconds = audioStartSeconds
            chapter.audioSegments = audioSegments
            chapter.lastError = lastError
            chapter.matterKind = matterKind
            chapter.includeInNarration = includeInNarration
            return chapter
        }
    }

    /// `book.json` payload: all BookProject fields except chapter texts,
    /// source/raw chapters and the cover image (those live in separate
    /// files).
    struct BookMetadata: Codable {
        var id: UUID
        var title: String
        var author: String
        var sourceType: SourceDocumentType
        var sourceURL: URL
        var chapters: [ChapterMetadata]
        var mode: ProcessingMode
        var documentType: DocumentType
        var targetChapterCharacters: Int?
        var summarizationBudget: Int?
        var outputFormat: OutputFormat
        var engineID: TTSEngineID
        var voice: String
        var speechSpeed: Double
        var detectedLanguageCode: String?
        var languageOverride: String?
        var summaryLanguageCode: String?
        var status: BookProjectStatus
        var currentStage: PipelineStage?
        var narratorLabel: String
        var sourceNote: String
        var outputDirectoryURL: URL?
        var createdAt: Date
        var logFileURL: URL?
        var lastErrorMessage: String?
        var detectedImageCount: Int?
        var describeImages: Bool?
        var packagedAudio: PackagedAudioInfo?
        var topic: String?
        var topicConfidence: Double?
        var topicOverride: String?
        var folderID: UUID?
        var ambientSound: String?
        var ambientVolumePercent: Int?
        /// Previous narration while re-voicing (v4) — must survive a crash
        /// so the old version can still be restored. Only present during
        /// a re-voicing run.
        var revoiceBackup: RevoiceBackup?
        /// `sourceChapters` are identical to `rawImportedChapters` — only
        /// `text/raw.json` exists and both sides read from it.
        var sourceChaptersSameAsRaw: Bool = false

        init(book: BookProject) {
            id = book.id
            title = book.title
            author = book.author
            sourceType = book.sourceType
            sourceURL = book.sourceURL
            chapters = book.sortedChapters.map(ChapterMetadata.init)
            mode = book.mode
            documentType = book.documentType
            targetChapterCharacters = book.targetChapterCharacters
            summarizationBudget = book.summarizationBudget
            outputFormat = book.outputFormat
            engineID = book.engineID
            voice = book.voice
            speechSpeed = book.speechSpeed
            detectedLanguageCode = book.detectedLanguageCode
            languageOverride = book.languageOverride
            summaryLanguageCode = book.summaryLanguageCode
            status = book.status
            currentStage = book.currentStage
            narratorLabel = book.narratorLabel
            sourceNote = book.sourceNote
            outputDirectoryURL = book.outputDirectoryURL
            createdAt = book.createdAt
            logFileURL = book.logFileURL
            lastErrorMessage = book.lastErrorMessage
            detectedImageCount = book.detectedImageCount
            describeImages = book.describeImages
            packagedAudio = book.packagedAudio
            topic = book.topic
            topicConfidence = book.topicConfidence
            topicOverride = book.topicOverride
            folderID = book.folderID
            ambientSound = book.ambientSound
            ambientVolumePercent = book.ambientVolumePercent
            revoiceBackup = book.revoiceBackup
            sourceChaptersSameAsRaw = book.sourceChapters != nil
                && book.sourceChapters == book.rawImportedChapters
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
            sourceType = try c.decode(SourceDocumentType.self, forKey: .sourceType)
            sourceURL = try c.decode(URL.self, forKey: .sourceURL)
            chapters = try c.decodeIfPresent([ChapterMetadata].self, forKey: .chapters) ?? []
            mode = try c.decodeIfPresent(ProcessingMode.self, forKey: .mode) ?? .transcription
            documentType = try c.decodeIfPresent(DocumentType.self, forKey: .documentType) ?? .general
            targetChapterCharacters = try c.decodeIfPresent(Int.self, forKey: .targetChapterCharacters)
            summarizationBudget = try c.decodeIfPresent(Int.self, forKey: .summarizationBudget)
            outputFormat = try c.decode(OutputFormat.self, forKey: .outputFormat)
            engineID = try c.decodeIfPresent(TTSEngineID.self, forKey: .engineID) ?? .kokoro
            voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
            speechSpeed = try c.decodeIfPresent(Double.self, forKey: .speechSpeed) ?? 1.0
            detectedLanguageCode = try c.decodeIfPresent(String.self, forKey: .detectedLanguageCode)
            languageOverride = try c.decodeIfPresent(String.self, forKey: .languageOverride)
            summaryLanguageCode = try c.decodeIfPresent(String.self, forKey: .summaryLanguageCode)
            status = try c.decodeIfPresent(BookProjectStatus.self, forKey: .status) ?? .needsReview
            currentStage = try c.decodeIfPresent(PipelineStage.self, forKey: .currentStage)
            narratorLabel = try c.decodeIfPresent(String.self, forKey: .narratorLabel) ?? ""
            sourceNote = try c.decodeIfPresent(String.self, forKey: .sourceNote) ?? ""
            outputDirectoryURL = try c.decodeIfPresent(URL.self, forKey: .outputDirectoryURL)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            logFileURL = try c.decodeIfPresent(URL.self, forKey: .logFileURL)
            lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage)
            detectedImageCount = try c.decodeIfPresent(Int.self, forKey: .detectedImageCount)
            describeImages = try c.decodeIfPresent(Bool.self, forKey: .describeImages)
            packagedAudio = try c.decodeIfPresent(PackagedAudioInfo.self, forKey: .packagedAudio)
            topic = try c.decodeIfPresent(String.self, forKey: .topic)
            topicConfidence = try c.decodeIfPresent(Double.self, forKey: .topicConfidence)
            topicOverride = try c.decodeIfPresent(String.self, forKey: .topicOverride)
            folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
            ambientSound = try c.decodeIfPresent(String.self, forKey: .ambientSound)
            ambientVolumePercent = try c.decodeIfPresent(Int.self, forKey: .ambientVolumePercent)
            revoiceBackup = try c.decodeIfPresent(RevoiceBackup.self, forKey: .revoiceBackup)
            sourceChaptersSameAsRaw = try c.decodeIfPresent(Bool.self, forKey: .sourceChaptersSameAsRaw) ?? false
        }

        /// Metadata-only BookProject: chapter texts are empty until
        /// `hydrate` merges `text/chapters.json` in.
        var book: BookProject {
            var book = BookProject(
                title: title,
                author: author,
                sourceType: sourceType,
                sourceURL: sourceURL,
                chapters: chapters.map(\.chapter),
                outputFormat: outputFormat,
                voice: voice,
                speechSpeed: speechSpeed
            )
            book.id = id
            book.mode = mode
            book.documentType = documentType
            book.targetChapterCharacters = targetChapterCharacters
            book.summarizationBudget = summarizationBudget
            book.engineID = engineID
            book.detectedLanguageCode = detectedLanguageCode
            book.languageOverride = languageOverride
            book.summaryLanguageCode = summaryLanguageCode
            book.status = status
            book.currentStage = currentStage
            book.narratorLabel = narratorLabel
            book.sourceNote = sourceNote
            book.outputDirectoryURL = outputDirectoryURL
            book.createdAt = createdAt
            book.logFileURL = logFileURL
            book.lastErrorMessage = lastErrorMessage
            book.detectedImageCount = detectedImageCount
            book.describeImages = describeImages
            book.packagedAudio = packagedAudio
            book.topic = topic
            book.topicConfidence = topicConfidence
            book.topicOverride = topicOverride
            book.folderID = folderID
            book.ambientSound = ambientSound
            book.ambientVolumePercent = ambientVolumePercent
            book.revoiceBackup = revoiceBackup
            return book
        }
    }

    static func encodeBookMetadata(_ book: BookProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(BookMetadata(book: book))
    }

    static func decodeBookMetadata(_ data: Data) throws -> BookProject {
        try JSONDecoder().decode(BookMetadata.self, from: data).book
    }

    /// True when `sourceChapters` and `rawImportedChapters` are identical —
    /// only one of the two files is written then.
    static func sourceChaptersSameAsRaw(_ book: BookProject) -> Bool {
        book.sourceChapters != nil && book.sourceChapters == book.rawImportedChapters
    }

    // MARK: - Chapter texts (text/chapters.json)

    struct ChapterTextRecord: Codable {
        var id: UUID
        /// Only written when different from `cleanedText` (dedupe). The
        /// decoder restores `rawText = cleanedText` when absent.
        var rawText: String?
        var cleanedText: String
        var summarizedText: String?
    }

    static func encodeChapterTexts(_ book: BookProject) throws -> Data {
        let records = book.sortedChapters.map { chapter -> ChapterTextRecord in
            ChapterTextRecord(
                id: chapter.id,
                rawText: chapter.rawText == chapter.cleanedText ? nil : chapter.rawText,
                cleanedText: chapter.cleanedText,
                summarizedText: chapter.summarizedText
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records)
    }

    static func decodeChapterTexts(_ data: Data) throws -> [ChapterTextRecord] {
        try JSONDecoder().decode([ChapterTextRecord].self, from: data)
    }

    /// Merges stored texts (and source/raw chapters, cover) into a
    /// metadata-only book in place.
    static func hydrate(_ book: inout BookProject, root: URL, sourceChaptersSameAsRaw: Bool = false) {
        let bookID = book.id
        if let data = try? Data(contentsOf: chapterTextsURL(root, bookID: bookID)),
           let records = try? decodeChapterTexts(data) {
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in book.chapters.indices {
                guard let record = byID[book.chapters[index].id] else { continue }
                book.chapters[index].cleanedText = record.cleanedText
                book.chapters[index].rawText = record.rawText ?? record.cleanedText
                book.chapters[index].summarizedText = record.summarizedText
            }
        }
        if let data = try? Data(contentsOf: rawChaptersURL(root, bookID: bookID)),
           let raw = try? JSONDecoder().decode([Chapter].self, from: data) {
            book.rawImportedChapters = raw
            if sourceChaptersSameAsRaw, book.sourceChapters == nil {
                book.sourceChapters = raw
            }
        }
        if book.sourceChapters == nil,
           let data = try? Data(contentsOf: sourceChaptersURL(root, bookID: bookID)),
           let source = try? JSONDecoder().decode([Chapter].self, from: data) {
            book.sourceChapters = source
        }
        if let data = try? Data(contentsOf: coverURL(root, bookID: bookID)) {
            book.coverImageData = data
        }
    }

    /// Whether the narration texts of `book` differ from the last persisted
    /// snapshot. Used to skip re-encoding the (large) text files when only
    /// chapter audio metadata changed — the common case during synthesis.
    static func textsDiffer(_ book: BookProject, persisted: BookProject?) -> Bool {
        guard let persisted else { return true }
        let lhs = book.sortedChapters
        let rhs = persisted.sortedChapters
        guard lhs.count == rhs.count else { return true }
        for (a, b) in zip(lhs, rhs) {
            if a.id != b.id { return true }
            if a.cleanedText != b.cleanedText { return true }
            if a.rawText != b.rawText { return true }
            if a.summarizedText != b.summarizedText { return true }
        }
        if book.sourceChapters != persisted.sourceChapters { return true }
        if book.rawImportedChapters != persisted.rawImportedChapters { return true }
        return false
    }

    // MARK: - Disk writes

    /// Writes a book's files (metadata, texts, source/raw). Each file is
    /// written atomically; `writeTexts` lets the caller skip re-encoding
    /// the (large) text files when only chapter audio metadata changed —
    /// the common case during synthesis.
    @discardableResult
    static func writeBook(_ book: BookProject, root: URL, writeTexts: Bool = true) throws -> Bool {
        let bookID = book.id
        let directory = bookDirectory(root, bookID: bookID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDirectory(root, bookID: bookID), withIntermediateDirectories: true)

        try encodeBookMetadata(book).write(to: bookMetadataURL(root, bookID: bookID), options: .atomic)

        var rewroteTexts = false
        if writeTexts {
            let sameAsRaw = sourceChaptersSameAsRaw(book)
            let encoder = JSONEncoder()
            if let source = book.sourceChapters {
                if !sameAsRaw {
                    try encoder.encode(source).write(to: sourceChaptersURL(root, bookID: bookID), options: .atomic)
                    rewroteTexts = true
                }
            } else {
                try? FileManager.default.removeItem(at: sourceChaptersURL(root, bookID: bookID))
            }
            if let raw = book.rawImportedChapters {
                try encoder.encode(raw).write(to: rawChaptersURL(root, bookID: bookID), options: .atomic)
                rewroteTexts = true
            } else {
                try? FileManager.default.removeItem(at: rawChaptersURL(root, bookID: bookID))
            }
            if sameAsRaw {
                // Both sides read text/raw.json — the source copy is redundant.
                try? FileManager.default.removeItem(at: sourceChaptersURL(root, bookID: bookID))
            }
            try encodeChapterTexts(book).write(to: chapterTextsURL(root, bookID: bookID), options: .atomic)
            rewroteTexts = true
        }
        return rewroteTexts
    }

    /// Metadata-only book from disk, or nil when the directory is missing
    /// or unreadable.
    static func readBook(bookID: UUID, root: URL) -> BookProject? {
        readStoredBook(bookID: bookID, root: root)?.book
    }

    struct StoredBook {
        var book: BookProject
        var sourceChaptersSameAsRaw: Bool
    }

    static func readStoredBook(bookID: UUID, root: URL) -> StoredBook? {
        guard let data = try? Data(contentsOf: bookMetadataURL(root, bookID: bookID)),
              let metadata = try? JSONDecoder().decode(BookMetadata.self, from: data) else { return nil }
        return StoredBook(book: metadata.book, sourceChaptersSameAsRaw: metadata.sourceChaptersSameAsRaw)
    }

    static func removeBookDirectory(bookID: UUID, root: URL) {
        try? FileManager.default.removeItem(at: bookDirectory(root, bookID: bookID))
    }

    // MARK: - Cover

    /// Writes the cover (and its 256 px sidebar thumbnail) as JPEG files.
    /// No-op for books without cover image data.
    static func writeCoverFiles(_ book: BookProject, root: URL) throws {
        guard let imageData = book.coverImageData else { return }
        let bookID = book.id
        if let jpeg = coverJPEGData(from: imageData) {
            try jpeg.write(to: coverURL(root, bookID: bookID), options: .atomic)
        }
        if let thumb = coverThumbJPEGData(from: imageData) {
            try thumb.write(to: coverThumbURL(root, bookID: bookID), options: .atomic)
        }
    }

    /// Re-encodes arbitrary image data as JPEG (the cover is stored as a
    /// file, not Base64 in JSON). Returns nil for undecodable data.
    static func coverJPEGData(from imageData: Data?) -> Data? {
        guard let imageData, let image = NSImage(data: imageData) else { return nil }
        let rep = bestRepresentation(of: image, maxPixel: nil)
        return rep.flatMap { rep in rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) }
    }

    /// Sidebar thumbnail: 256 px on the long edge, JPEG.
    static func coverThumbJPEGData(from imageData: Data?, maxPixel: CGFloat = 256) -> Data? {
        guard let imageData, let image = NSImage(data: imageData) else { return nil }
        let rep = bestRepresentation(of: image, maxPixel: maxPixel)
        return rep.flatMap { rep in rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) }
    }

    private static func bestRepresentation(of image: NSImage, maxPixel: CGFloat?) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation, let source = NSBitmapImageRep(data: tiff) else { return nil }
        guard let maxPixel else { return source }
        let width = CGFloat(source.pixelsWide)
        let height = CGFloat(source.pixelsHigh)
        let longest = max(width, height)
        guard longest > maxPixel, longest > 0 else { return source }
        let scale = maxPixel / longest
        let newSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize))
        NSGraphicsContext.current?.flushGraphics()
        newImage.unlockFocus()
        guard let scaledTIFF = newImage.tiffRepresentation else { return source }
        return NSBitmapImageRep(data: scaledTIFF) ?? source
    }
}
