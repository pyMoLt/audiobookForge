import Foundation

struct Chapter: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var title: String
    var rawText: String
    /// Text after header/footer stripping, footnote handling etc. This is what
    /// gets read aloud in transcription mode, or summarized in summary mode.
    var cleanedText: String
    /// Populated once the summarizer has run for this chapter (summary mode only).
    var summarizedText: String?
    var order: Int
    var audioStatus: ChapterAudioStatus = .pending
    var audioFileURL: URL?
    var audioDurationSeconds: Double?
    /// Best-effort sentence-level timing for the built-in player's position
    /// indicator. Optional by design — absent for any engine/run that
    /// couldn't produce it, in which case the player just falls back to
    /// plain chapter-level progress.
    var audioSegments: [TTSSegment]?
    var lastError: String?

    /// Falls back to a bare unwrap (keep the content, drop the tags) as a
    /// safety net for any consumer reading this before the pipeline has run
    /// its own scope-aware resolution — e.g. a voice preview taken right
    /// after import. Once the pipeline runs, `cleanedText` has already been
    /// resolved in place (see `PipelineController.resolveImageDescriptionMarkers`),
    /// so this is a no-op at that point.
    var textForNarration: String {
        ImageDescriptionMarker.unwrap(summarizedText ?? cleanedText)
    }
}

struct BookProject: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var title: String
    var author: String
    var sourceType: SourceDocumentType
    var sourceURL: URL
    var chapters: [Chapter]
    var mode: ProcessingMode = .transcription
    /// Set from `AppSettings.defaultDocumentType` at import time; changeable
    /// here afterward. Only affects the summarization batching budget going
    /// forward — the chapter-merge threshold it also influences is already
    /// baked into `chapters` by the time this is editable, since re-running
    /// that would mean re-extracting from the source file.
    var documentType: DocumentType = .general
    /// A frozen snapshot of `chapters` taken the first time this book is run
    /// in summary mode (including whatever manual reordering/renaming/
    /// deletion the user already did in the review screen by then) — before
    /// `chapters` gets replaced with the AI's own restructured result. All
    /// later summary-mode runs re-summarize from this snapshot, never from a
    /// previous AI-derived `chapters`, so re-running summarization never
    /// summarizes the model's own prior output. Switching back to
    /// transcription mode restores `chapters` from here too, so the real
    /// document structure survives having tried summary mode at all. `nil`
    /// until summary mode has actually run once.
    var sourceChapters: [Chapter]?
    /// Raw atomic chapters as originally extracted upon import. Preserved
    /// so the user can dynamically adjust chapter granularity in the review screen.
    var rawImportedChapters: [Chapter]?
    /// Target chapter size in characters for 1:1 narration (transcription mode).
    var targetChapterCharacters: Int?
    /// Target batch budget in characters for LLM summarization.
    var summarizationBudget: Int?
    var outputFormat: OutputFormat
    var engineID: TTSEngineID = .kokoro
    var voice: String
    var speechSpeed: Double
    /// BCP-47-ish language code guessed from the extracted text (e.g. "de",
    /// "en"), used to suggest a matching engine/voice. Always
    /// user-overridable in the review screen.
    var detectedLanguageCode: String?
    /// Language chosen by the user in the review screen; wins over detection.
    var languageOverride: String?
    /// Output language of AI summaries; nil = same as the book.
    var summaryLanguageCode: String?

    /// The book's language: user choice, else detection, else German.
    var languageCode: String { languageOverride ?? detectedLanguageCode ?? "de" }
    /// Language the narration is produced in for the current mode.
    var outputLanguageCode: String { mode == .summary ? (summaryLanguageCode ?? languageCode) : languageCode }
    var status: BookProjectStatus = .needsReview
    var currentStage: PipelineStage?
    var narratorLabel: String = ""
    var sourceNote: String = ""
    var coverImageData: Data?
    var outputDirectoryURL: URL?
    var createdAt: Date = Date()
    var logFileURL: URL?
    var lastErrorMessage: String?
    var detectedImageCount: Int?
    /// Per-book override of "describe figures"; nil = global setting.
    var describeImages: Bool?

    var sortedChapters: [Chapter] {
        chapters.sorted { $0.order < $1.order }
    }

    static func == (lhs: BookProject, rhs: BookProject) -> Bool {
        lhs.id == rhs.id
    }
}
