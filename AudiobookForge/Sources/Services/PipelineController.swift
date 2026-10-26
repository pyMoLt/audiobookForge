import Foundation
import PDFKit

@MainActor
@Observable
final class PipelineController {
    private let libraryStore: LibraryStore
    private let settingsStore: SettingsStore

    /// Only one book actually runs its pipeline at a time — TTS synthesis
    /// saturates the local GPU/CPU, so running several books "concurrently"
    /// would just make all of them slower. Everything else waits in a
    /// visible, reorderable FIFO queue.
    private(set) var activeBookID: UUID?
    private(set) var queuedBookIDs: [UUID] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Live progress of running books (not persisted). See `RunProgress`.
    /// Mutations are throttled through `coalescer` (≤ 4 UI updates/s);
    /// stage switches and completions pass `immediate: true`.
    private(set) var progress: [UUID: RunProgress] = [:]
    private let coalescer: ProgressCoalescer

    func updateProgress(_ bookID: UUID, immediate: Bool = false, _ mutate: @escaping (inout RunProgress) -> Void) {
        coalescer.mutate(bookID: bookID, immediate: immediate, mutate)
    }

    private func enterStage(_ bookID: UUID, _ stage: PipelineStage, detail: String = "") {
        updateProgress(bookID, immediate: true) {
            $0.enterStage(stage, detail: detail)
        }
    }

    /// Test isolation: chapter audio and run logs land in these roots
    /// (defaults = the user's real Application Support directories).
    private let chapterAudioRoot: URL
    private let logsDirectory: URL?

    init(libraryStore: LibraryStore, settingsStore: SettingsStore, chapterAudioRoot: URL = AppPaths.chapterAudioRoot, logsDirectory: URL? = nil) {
        self.libraryStore = libraryStore
        self.settingsStore = settingsStore
        self.chapterAudioRoot = chapterAudioRoot
        self.logsDirectory = logsDirectory
        let coalescer = ProgressCoalescer()
        self.coalescer = coalescer
        coalescer.apply = { [weak self] bookID, mutations in
            guard let self, var current = self.progress[bookID] else { return }
            for mutation in mutations { mutation(&current) }
            self.progress[bookID] = current
        }
    }

    func isRunning(_ bookID: UUID) -> Bool {
        activeBookID == bookID
    }

    func isQueued(_ bookID: UUID) -> Bool {
        queuedBookIDs.contains(bookID)
    }

    /// Adds a book to the processing queue. Starts immediately if nothing
    /// else is running; otherwise waits its turn.
    func enqueue(bookID: UUID) {
        guard activeBookID != bookID, !queuedBookIDs.contains(bookID) else { return }
        guard var book = libraryStore.book(id: bookID) else { return }
        book.lastErrorMessage = nil

        if activeBookID == nil {
            book.status = .processing
            libraryStore.upsert(book)
            startActive(bookID: bookID)
        } else {
            book.status = .queued
            libraryStore.upsert(book)
            queuedBookIDs.append(bookID)
        }
    }

    private var pausedBookIDs: Set<UUID> = []
    private var ramWatchdogTriggered: [UUID: String] = [:]

    func isPaused(_ bookID: UUID) -> Bool {
        libraryStore.book(id: bookID)?.status == .paused
    }

    func pauseProcessing(bookID: UUID) {
        guard activeBookID == bookID || queuedBookIDs.contains(bookID) else { return }
        pausedBookIDs.insert(bookID)
        if activeBookID == bookID {
            tasks[bookID]?.cancel()
        } else if let index = queuedBookIDs.firstIndex(of: bookID) {
            queuedBookIDs.remove(at: index)
            if var book = libraryStore.book(id: bookID) {
                book.status = .paused
                libraryStore.upsert(book)
            }
        }
    }

    func resumeProcessing(bookID: UUID) {
        guard let book = libraryStore.book(id: bookID), book.status == .paused || book.status == .failed else { return }
        enqueue(bookID: bookID)
    }

    /// Removes a book from the queue (if merely waiting) or cancels it (if
    /// actively running), then automatically promotes the next queued book.
    /// Cancellation rolls back progress and cleans up intermediate chapter audio.
    func cancelProcessing(bookID: UUID) {
        pausedBookIDs.remove(bookID)
        if activeBookID == bookID {
            tasks[bookID]?.cancel()
            // Keep the slot occupied until its subprocesses have actually
            // terminated and runFullPipeline has unwound.
        } else if let index = queuedBookIDs.firstIndex(of: bookID) {
            queuedBookIDs.remove(at: index)
            if var book = libraryStore.book(id: bookID) {
                if book.revoiceBackup != nil {
                    Revoicing.restore(&book, chapterAudioRoot: chapterAudioRoot)
                } else {
                    book.status = .needsReview
                    resetBookAudioState(&book)
                }
                libraryStore.upsert(book)
            }
        } else if var book = libraryStore.book(id: bookID), book.status == .paused || book.status == .failed {
            if book.revoiceBackup != nil {
                Revoicing.restore(&book, chapterAudioRoot: chapterAudioRoot)
            } else {
                book.status = .needsReview
                resetBookAudioState(&book)
            }
            libraryStore.upsert(book)
        }
    }

    // MARK: - Re-voicing (v4)

    /// Speaks a finished book again with another voice (summary or plain
    /// narration). The stored text — LLM summaries, image descriptions —
    /// is reused unless `resummarize` asks for a fresh summary. Returns
    /// false when the book is busy.
    @discardableResult
    func revoice(bookID: UUID, engine: TTSEngineID, voice: String, speed: Double, resummarize: Bool = false) -> Bool {
        guard activeBookID != bookID, !queuedBookIDs.contains(bookID), var book = libraryStore.book(id: bookID) else { return false }
        Revoicing.prepare(&book, engine: engine, voice: voice, speed: speed, resummarize: resummarize, chapterAudioRoot: chapterAudioRoot)
        libraryStore.upsert(book)
        enqueue(bookID: bookID)
        return true
    }

    /// At launch (v4.1) nothing runs yet: a book that still carries a
    /// re-voicing backup was interrupted (crash, force quit). Put its
    /// previous narration back — except for a paused run, which the user
    /// can resume. Returns the restored books.
    @discardableResult
    func recoverInterruptedRevoicing() -> [UUID] {
        let fm = FileManager.default
        let candidates = libraryStore.books.filter { book in
            book.revoiceBackup != nil
                || fm.fileExists(atPath: LibraryLayout.revoiceBackupURL(libraryStore.rootURL, bookID: book.id).path)
        }.map(\.id)
        var restored: [UUID] = []
        for id in candidates {
            guard activeBookID != id, !queuedBookIDs.contains(id),
                  var book = libraryStore.book(id: id), book.revoiceBackup != nil, book.status != .paused else { continue }
            Revoicing.restore(&book, chapterAudioRoot: chapterAudioRoot)
            book.lastErrorMessage = L("Neu vertonen wurde unterbrochen — die bisherige Fassung ist wiederhergestellt.")
            libraryStore.upsert(book)
            restored.append(id)
        }
        if !restored.isEmpty { libraryStore.flush() }
        return restored
    }

    /// After a run: commit a finished re-voicing, keep a paused one, put
    /// the previous narration back for anything else.
    private func finishRevoiceIfNeeded(bookID: UUID) {
        guard var book = libraryStore.book(id: bookID), book.revoiceBackup != nil else { return }
        switch book.status {
        case .completed:
            Revoicing.commit(&book, chapterAudioRoot: chapterAudioRoot)
        case .paused, .processing, .queued:
            return
        case .failed, .needsReview:
            let reason = book.lastErrorMessage
            Revoicing.restore(&book, chapterAudioRoot: chapterAudioRoot)
            book.lastErrorMessage = reason.map { L("Neu vertonen fehlgeschlagen — die bisherige Fassung bleibt erhalten:") + " " + $0 }
        }
        libraryStore.upsert(book)
    }

    private func resetBookAudioState(_ book: inout BookProject) {
        ChapterAudioStore.removeChapterAudio(bookID: book.id, root: chapterAudioRoot)
        for i in book.chapters.indices {
            book.chapters[i].audioStatus = .pending
            book.chapters[i].audioFileURL = nil
            book.chapters[i].audioDurationSeconds = nil
            book.chapters[i].audioSegments = nil
            book.chapters[i].lastError = nil
        }
        if book.mode == .summary, let source = book.sourceChapters {
            book.chapters = source
        }
        book.currentStage = nil
        book.lastErrorMessage = nil
    }

    func moveQueuedBook(id: UUID, toIndex targetIndex: Int) {
        guard let sourceIndex = queuedBookIDs.firstIndex(of: id) else { return }
        let item = queuedBookIDs.remove(at: sourceIndex)
        let insertionIndex = min(max(targetIndex, 0), queuedBookIDs.count)
        queuedBookIDs.insert(item, at: insertionIndex)
    }

    private func startActive(bookID: UUID) {
        activeBookID = bookID
        let task = Task { [weak self] in
            await self?.runFullPipeline(bookID: bookID)
            await MainActor.run {
                guard let self else { return }
                self.finishRevoiceIfNeeded(bookID: bookID)
                self.coalescer.drop(bookID: bookID)
                self.progress[bookID] = nil
                if self.activeBookID == bookID {
                    self.activeBookID = nil
                }
                self.tasks[bookID] = nil
                self.startNextQueuedIfIdle()
            }
        }
        tasks[bookID] = task
    }

    private func startNextQueuedIfIdle() {
        guard activeBookID == nil, !queuedBookIDs.isEmpty else { return }
        let nextID = queuedBookIDs.removeFirst()
        guard var book = libraryStore.book(id: nextID) else {
            startNextQueuedIfIdle()
            return
        }
        book.status = .processing
        libraryStore.upsert(book)
        startActive(bookID: nextID)
    }

    var isAnyBookActive: Bool { activeBookID != nil }

    func regenerateChapter(bookID: UUID, chapterID: UUID) {
        guard activeBookID == nil else { return }
        activeBookID = bookID

        let task = Task { [weak self] in
            await self?.runSingleChapterRegeneration(bookID: bookID, chapterID: chapterID)
            await MainActor.run {
                guard let self else { return }
                self.coalescer.drop(bookID: bookID)
                self.progress[bookID] = nil
                if self.activeBookID == bookID {
                    self.activeBookID = nil
                }
                self.tasks[bookID] = nil
                self.startNextQueuedIfIdle()
            }
        }
        tasks[bookID] = task
    }

    /// If summarization mode was selected but the LLM endpoint turns out to
    /// be unreachable, this switches the book to transcription mode so the
    /// user can continue without losing their place — no silent failure, no
    /// dead end.
    func fallBackToTranscription(bookID: UUID) {
        guard var book = libraryStore.book(id: bookID) else { return }
        if let sourceChapters = book.sourceChapters { book.chapters = sourceChapters }
        book.mode = .transcription
        book.lastErrorMessage = nil
        book.status = .needsReview
        libraryStore.upsert(book)
    }

    // MARK: - Figures (image descriptions)

    /// Whether this run narrates/summarizes figure descriptions at all.
    private func describesFigures(_ book: BookProject) -> Bool {
        let settings = settingsStore.settings
        guard book.describeImages ?? settings.describeImagesWithVisionModel else { return false }
        return book.mode == .summary ? settings.imageDescriptionScope.includesSummaryMode : settings.imageDescriptionScope.includesTranscriptionMode
    }

    /// Whether this chapter should reach narration and the figure pass
    /// (plan 6.2): excluded by user decision, or auto-suggested as
    /// skippable (TOC/front matter) without a user override — TOC pages
    /// used to be "described" as figures, wasting vision calls.
    private func isIncludedInNarration(_ chapter: Chapter) -> Bool {
        if chapter.includeInNarration == false { return false }
        if let kind = chapter.matterKind, FrontBackMatterClassifier.suggestsSkipping(kind), chapter.includeInNarration != true { return false }
        return true
    }

    /// Text as it is actually consumed (narrated or summarized): figure
    /// descriptions become plain "Abbildung: …" paragraphs at their place,
    /// or vanish when figures are off for this run. Stored chapter text
    /// keeps its markers so a later run (other mode, other setting) can
    /// decide again without re-importing or re-describing.
    private func narrationText(for chapter: Chapter, book: BookProject) -> String {
        Self.narration(
            for: chapter,
            describeFigures: describesFigures(book),
            removeReferences: settingsStore.settings.removeCrossReferences,
            boxLabelHandling: settingsStore.settings.boxLabelHandling,
            speakHeadingNumbers: settingsStore.settings.speakHeadingNumbers,
            languageCode: book.outputLanguageCode
        )
    }

    /// The exact text the engine speaks for `chapter` — the read-along page
    /// uses it so highlighted sentences match the audio 1:1 (v3.1).
    nonisolated static func spokenText(for chapter: Chapter, book: BookProject, settings: AppSettings) -> String {
        let describes: Bool = {
            guard book.describeImages ?? settings.describeImagesWithVisionModel else { return false }
            return book.mode == .summary ? settings.imageDescriptionScope.includesSummaryMode : settings.imageDescriptionScope.includesTranscriptionMode
        }()
        return narration(for: chapter, describeFigures: describes, removeReferences: settings.removeCrossReferences,
                         boxLabelHandling: settings.boxLabelHandling, speakHeadingNumbers: settings.speakHeadingNumbers,
                         languageCode: book.outputLanguageCode)
    }

    nonisolated private static func narration(for chapter: Chapter, describeFigures: Bool, removeReferences: Bool, boxLabelHandling: BoxLabelHandling, speakHeadingNumbers: Bool, languageCode: String) -> String {
        let base: String
        if let summary = chapter.summarizedText {
            base = ImageDescriptionMarker.unwrap(summary)
        } else {
            base = describeFigures ? ImageDescriptionMarker.unwrap(chapter.cleanedText) : ImageDescriptionMarker.stripBlocks(from: chapter.cleanedText)
        }
        // Box labels and list/heading numbering shape only the spoken
        // text — the stored chapter text keeps its markers (plan 6.1/6.4).
        let withoutLabels = BoxLabelFilter.apply(base, handling: boxLabelHandling).text
        let normalized = ListNumberingFilter.apply(withoutLabels, speakHeadingNumbers: speakHeadingNumbers).text
        // Pronunciation shaping happens after the text filters and before
        // the cross-reference pass (plan 6.6); stored text is untouched.
        let spoken = PronunciationLexicon.apply(normalized, languageCode: languageCode)
        return removeReferences ? PDFTextbookCleaner.removeCrossReferences(spoken) : spoken
    }

    /// "Abbildung: Die Abbildung zeigt …" reads clumsily — drop such
    /// openings (the label already announces the figure).
    nonisolated static func withoutFillerOpening(_ text: String) -> String {
        let pattern = #"^(Die|Diese|Das|Dieses)\s+(Abbildung|Bild|Grafik|Aufnahme|Darstellung|Illustration)\s+(zeigt|stellt dar|veranschaulicht|präsentiert)\s*:?\s*|^(The|This)\s+(image|figure|picture|illustration)\s+(shows|displays|depicts|illustrates)\s*:?\s*"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return text }
        let rest = text[range.upperBound...]
        guard let first = rest.first else { return text }
        return first.uppercased() + rest.dropFirst()
    }

    private func figureLabel(for book: BookProject) -> String {
        let custom = settingsStore.settings.imageDescriptionLabel.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom.hasSuffix(":") ? custom : custom + ":" }
        return PausePlanner.figureLabel(forLanguage: book.outputLanguageCode)
    }

    private func languageName(for book: BookProject) -> String {
        LanguageDetector.englishName(book.outputLanguageCode)
    }

    /// Figures that still need a description of the required length,
    /// after the current size filters. Pure function, runs off the main
    /// thread (opens the PDF only to read page sizes).
    private struct FigurePlan: Sendable {
        var pending: [FigureReference] = []
        var rejectedKeys: Set<String> = []
        var total = 0
        var cached = 0
    }

    nonisolated private static func planFigures(texts: [String], length: FigureDescriptionLength, sourceURL: URL, isPDF: Bool, settings: AppSettings) -> FigurePlan {
        autoreleasepool {
            var plan = FigurePlan()
            var seen = Set<String>()
            var candidates: [FigureReference] = []
            for text in texts {
                for figure in ImageDescriptionMarker.figures(in: text) where !seen.contains(figure.ref.key) {
                    seen.insert(figure.ref.key)
                    if figure.existing == length { plan.cached += 1 } else { candidates.append(figure.ref) }
                }
            }
            plan.total = seen.count
            let document = isPDF && !candidates.isEmpty ? PDFDocument(url: sourceURL) : nil
            let thresholds = PDFFigureDetector.Thresholds(
                minimumPixelSize: settings.minimumImageDimensionForVisionPass,
                minimumAreaFraction: settings.minimumImageAreaPercent / 100,
                minimumKilobytes: settings.minimumImageKilobytes,
                maximumAspectRatio: settings.maximumImageAspectRatio,
                detectVectorFigures: settings.detectVectorFigures
            )
            for ref in candidates {
                if ref.kind == "vector" && !settings.detectVectorFigures { plan.rejectedKeys.insert(ref.key); continue }
                var pageArea: CGFloat = 0
                if let page = ref.page, let bounds = document?.page(at: page)?.bounds(for: .mediaBox) { pageArea = bounds.width * bounds.height }
                let figure = PDFFigureDetector.Figure(
                    rect: ref.cgRect ?? CGRect(x: 0, y: 0, width: 1000, height: 1000),
                    kind: ref.kind == "vector" ? .vector : .raster,
                    pixelWidth: ref.pixelWidth ?? 0, pixelHeight: ref.pixelHeight ?? 0,
                    encodedBytes: ref.encodedBytes ?? Int.max
                )
                var t = thresholds
                if pageArea == 0 { t.minimumAreaFraction = 0; pageArea = 1 }
                if PDFFigureDetector.passes(figure, pageArea: pageArea, thresholds: t) {
                    plan.pending.append(ref)
                } else {
                    plan.rejectedKeys.insert(ref.key)
                }
            }
            return plan
        }
    }

    /// Loads/renders one figure's image. Runs in a child task (never on
    /// the main thread); opens its own PDFDocument because PDFKit
    /// documents must not be shared across threads.
    nonisolated private static func figureImage(_ ref: FigureReference, sourceURL: URL, archiveRoot: URL?) -> Data? {
        autoreleasepool {
            switch ref.source {
            case .pdf:
                guard let page = ref.page, let rect = ref.cgRect, let document = PDFDocument(url: sourceURL) else { return nil }
                return FigureImageLoader.renderPDFRegion(document: document, pageIndex: page, rect: rect)
            case .epub:
                guard let archiveRoot, let path = ref.path else { return nil }
                return FigureImageLoader.loadArchiveImage(archiveRoot: archiveRoot, path: path)
            }
        }
    }

    /// Describes every figure that doesn't yet have a description of the
    /// length this run needs (full for narration, short for the
    /// summarizer), in parallel, and stores it at the figure's position in
    /// both `chapters` and `sourceChapters`. Placement is purely positional
    /// — the description replaces the figure's own marker — so no model is
    /// ever asked to place anything. All heavy work (marker scan, PDF
    /// rendering, network, text rewrite) happens off the main thread; the
    /// main actor only receives progress, so the UI stays responsive and a
    /// cancel takes effect immediately.
    private func describeFigures(in book: inout BookProject, logger: RunLogger) async {
        guard describesFigures(book) else { return }
        let settings = settingsStore.settings
        let length: FigureDescriptionLength = book.mode == .summary ? .short : .full
        let texts = book.chapters.filter(isIncludedInNarration).map(\.cleanedText)
            + (book.sourceChapters ?? []).filter(isIncludedInNarration).map(\.cleanedText)
        let sourceURL = book.sourceURL
        let isPDF = book.sourceType == .pdf

        let plan = await Task.detached(priority: .userInitiated) {
            PipelineController.planFigures(texts: texts, length: length, sourceURL: sourceURL, isPDF: isPDF, settings: settings)
        }.value
        guard plan.total > 0, !Task.isCancelled else { return }
        let pending = plan.pending

        if !pending.isEmpty {
            logger.log("Prüfe \(settings.llmProvider.displayName)-Server vor dem Bildpass …")
            let client = LLMClient(settings: settings)
            var reachable = false
            do {
                _ = try await client.listModels()
                reachable = true
            } catch {
                if settings.autoStartOMLX && settings.llmProvider == .omlx {
                    logger.log("oMLX-Server läuft nicht. Versuche automatischen Start (autoStartOMLX aktiv) …")
                    if await OMLXLifecycleManager.startServer(timeout: 45) {
                        logger.log("oMLX-Server erfolgreich im Hintergrund gestartet.")
                        do {
                            _ = try await client.listModels()
                            reachable = true
                        } catch {
                            reachable = false
                        }
                    } else {
                        logger.log("Automatischer Start von oMLX fehlgeschlagen.")
                    }
                }
            }
            if !reachable {
                let errorMsg = "\(settings.llmProvider.displayName)-Server ist nicht erreichbar (\(settings.activeLLMBaseURL)). Bitte starte \(settings.llmProvider.displayName) und setze die Verarbeitung fort."
                logger.log("Fehler: \(errorMsg)")
                book.status = .paused
                book.lastErrorMessage = errorMsg
                libraryStore.upsert(book)
                return
            }
        }

        book.currentStage = .describingImages
        libraryStore.upsert(book)
        enterStage(book.id, .describingImages, detail: "\(pending.count) Abbildungen")
        updateProgress(book.id) { $0.imagesTotal = pending.count; $0.imagesDone = 0 }
        logger.log("Bildpass: \(plan.total) Abbildungen, davon \(plan.cached) bereits beschrieben, \(plan.rejectedKeys.count) unter den Größenfiltern, \(pending.count) zu beschreiben (\(length == .full ? "ausführlich" : "kurz"), \(settings.visionParallelRequests) parallel, Sprache: \(LanguageDetector.displayName(book.outputLanguageCode))).")

        var archiveRoot: URL?
        if book.sourceType == .epub, !pending.isEmpty {
            archiveRoot = try? await EPUBExtractor.unzip(epubURL: sourceURL)
            if archiveRoot == nil { logger.log("  EPUB konnte für den Bildpass nicht entpackt werden — Bilder werden übersprungen.") }
        }
        defer { if let archiveRoot { try? FileManager.default.removeItem(at: archiveRoot) } }

        let prompt = (length == .full ? settings.promptTemplates.visionPrompt : settings.promptTemplates.visionPromptShort)
            .replacingOccurrences(of: "{{language}}", with: languageName(for: book))
        let bookID = book.id
        let root = archiveRoot
        var results: [String: String?] = [:] // key → description (nil = SKIP)
        let parallel = PowerProfile.current.llmRequests(configured: settings.visionParallelRequests)
        await withTaskGroup(of: (String, String??).self) { group in
            var next = 0
            var done = 0
            func launch(_ ref: FigureReference) {
                var context = ""
                if let caption = ref.caption, !caption.isEmpty { context += "Its caption in the book reads: \"\(caption)\"." }
                if let alt = ref.altText, !alt.isEmpty { context += " Its alternative text reads: \"\(alt)\"." }
                let filledPrompt = prompt.replacingOccurrences(of: "{{caption}}", with: context)
                group.addTask {
                    guard !Task.isCancelled, let image = PipelineController.figureImage(ref, sourceURL: sourceURL, archiveRoot: root) else { return (ref.key, .none) }
                    do {
                        let text = try await VisionDescriber.describe(jpegData: image, prompt: filledPrompt, settings: settings)
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (ref.key, .some(trimmed.uppercased().hasPrefix("SKIP") ? nil : PipelineController.withoutFillerOpening(trimmed)))
                    } catch {
                        return (ref.key, .none)
                    }
                }
            }
            while next < pending.count && next < parallel { launch(pending[next]); next += 1 }
            while let (key, outcome) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                done += 1
                switch outcome {
                case .some(.some(let text)): results[key] = text; logger.log("  [\(done)/\(pending.count)] → \"\(text.prefix(90))…\"")
                case .some(.none): results[key] = .some(nil); logger.log("  [\(done)/\(pending.count)] → übersprungen (dekorativ)")
                case .none: logger.log("  [\(done)/\(pending.count)] → fehlgeschlagen (Bild nicht ladbar oder Modell ohne Bildverständnis) — wird beim nächsten Lauf erneut versucht")
                }
                let snapshot = done
                updateProgress(bookID) {
                    $0.imagesDone = snapshot
                    $0.phaseFraction = Double(snapshot) / Double(max(pending.count, 1))
                    $0.detail = "Abbildung \(snapshot)/\(pending.count)"
                }
                if next < pending.count { launch(pending[next]); next += 1 }
            }
        }

        // Even after a cancel, keep what was already described (cached for
        // the next run) — the text rewrite also runs off the main thread.
        let label = figureLabel(for: book)
        let finished = results
        let chapterTexts = book.chapters.map(\.cleanedText)
        let sourceTexts = book.sourceChapters?.map(\.cleanedText)
        let rewritten = await Task.detached(priority: .userInitiated) { () -> ([String], [String]?) in
            func resolve(_ text: String) -> String {
                ImageDescriptionMarker.resolveFigures(in: text, dropLegacy: true) { ref, _ in
                    guard let outcome = finished[ref.key], let description = outcome else { return .keep }
                    return .describe("\(label) \(description)", length)
                }
            }
            return (chapterTexts.map(resolve), sourceTexts.map { $0.map(resolve) })
        }.value
        for index in book.chapters.indices where index < rewritten.0.count {
            book.chapters[index].cleanedText = rewritten.0[index]
        }
        if var sources = book.sourceChapters, let texts = rewritten.1 {
            for index in sources.indices where index < texts.count { sources[index].cleanedText = texts[index] }
            book.sourceChapters = sources
        }
        let described = results.values.compactMap { $0 }.count
        logger.log("Bildpass \(Task.isCancelled ? "abgebrochen" : "abgeschlossen"): \(described) beschrieben, \(results.values.filter { $0 == nil }.count) als dekorativ übersprungen, \(pending.count - results.count) offen/fehlgeschlagen.")
        libraryStore.upsert(book)
    }

    // MARK: - Full pipeline

    /// Book-wide numbers needed before a run starts. Computed off the main
    /// thread: decoding every figure marker and measuring a 700-page
    /// textbook used to freeze the UI at the start of a run.
    private struct RunAnalysis: Sendable {
        var hasFigures: Bool
        var pendingFigureKeys: Int
        var sourceCharacters: Int
        var detectedLanguage: String?
    }

    nonisolated private static func analyze(_ book: BookProject, redetectLanguage: Bool) -> RunAnalysis {
        let source = book.sourceChapters ?? book.chapters
        let figures = source.flatMap { ImageDescriptionMarker.figures(in: $0.cleanedText) }
        return RunAnalysis(
            hasFigures: !figures.isEmpty,
            pendingFigureKeys: Set(figures.filter { $0.existing == nil }.map(\.ref.key)).count,
            sourceCharacters: source.reduce(0) { $0 + ImageDescriptionMarker.stripBlocks(from: $1.cleanedText).count },
            detectedLanguage: redetectLanguage ? LanguageDetector.detectLanguageCode(chapterTexts: source.map(\.cleanedText)) : nil
        )
    }

    private struct PendingSynthesisItem: Sendable {
        let index: Int
        let order: Int
        let title: String
        let text: String
        let outputURL: URL
    }

    private struct ChapterSynthesisResult: Sendable {
        let index: Int
        let result: TTSSynthesisResult
    }

    /// Forwards a TTS engine event of one parallel worker to that
    /// chapter's `ChapterProgress`. Called from a background child task,
    /// so callers hop to the main actor; the update itself is throttled.
    private func reportSegmentEvent(bookID: UUID, chapterIndex: Int, event: TTSProgressEvent, totalCharacters: Int) {
        switch event {
        case .modelLoaded:
            break
        case .plannedSegments(let total):
            updateProgress(bookID) {
                $0.activeChapters[chapterIndex]?.plannedSegments = total
            }
        case .segmentDone(let segIdx, let duration):
            updateProgress(bookID) {
                guard var chapter = $0.activeChapters[chapterIndex] else { return }
                chapter.segmentsDone = segIdx + 1
                chapter.audioSeconds += duration
                if let planned = chapter.plannedSegments, planned > 0 {
                    chapter.fraction = min(1, Double(segIdx + 1) / Double(planned))
                } else {
                    chapter.fraction = min(0.999, chapter.fraction + 0.05)
                }
                $0.activeChapters[chapterIndex] = chapter
                if totalCharacters > 0 {
                    $0.phaseFraction = $0.synthesisTextFraction
                }
                $0.noteRateSample(value: $0.producedAudioSeconds, synthesis: true)
            }
        }
    }

    private func markChapterSynthesizing(bookID: UUID, index: Int, completedCount: Int, chaptersCount: Int) {        if var book = libraryStore.book(id: bookID), index < book.chapters.count {
            book.chapters[index].audioStatus = .synthesizing
            libraryStore.upsert(book)
            updateProgress(bookID) {
                $0.activeChapters[index] = RunProgress.ChapterProgress(index: index, title: book.chapters[index].title)
                $0.detail = "Kapitel \(completedCount + 1)/\(chaptersCount)"
            }
        }
    }

    private func recordChapterDone(
        bookID: UUID,
        index: Int,
        result: TTSSynthesisResult,
        synthesisStart: Date,
        totalCharacters: Int,
        chapterLengths: [Int],
        completedCount: Int,
        chaptersCount: Int
    ) -> ChapterAudioFile? {
        guard var book = libraryStore.book(id: bookID), index < book.chapters.count else { return nil }
        book.chapters[index].audioFileURL = result.audioFileURL
        book.chapters[index].audioDurationSeconds = result.durationSeconds
        book.chapters[index].audioSegments = result.segments
        book.chapters[index].audioStatus = .ready
        libraryStore.upsert(book)

        let audioFile = ChapterAudioFile(chapter: book.chapters[index], url: result.audioFileURL)

        updateProgress(bookID, immediate: true) { p in
            p.finishedAudioSeconds += result.durationSeconds
            p.activeChapters[index] = nil
            p.chaptersCompleted = completedCount
            p.synthesisWallSeconds = Date().timeIntervalSince(synthesisStart)
            if totalCharacters > 0 {
                let readyIndices = Set(book.chapters.enumerated().filter { $0.element.audioStatus == .ready }.map { $0.offset })
                let finishedChars = readyIndices.reduce(0) { sum, idx in idx < chapterLengths.count ? sum + chapterLengths[idx] : sum }
                p.phaseFraction = Double(finishedChars) / Double(totalCharacters)
            }
            p.noteRateSample(value: p.producedAudioSeconds, synthesis: true)
            p.detail = "Kapitel \(completedCount)/\(chaptersCount) fertig"
        }
        return audioFile
    }

    private func runFullPipeline(bookID: UUID) async {
        guard var initialBook = libraryStore.book(id: bookID) else { return }
        let logger = RunLogger(bookID: bookID, bookTitle: initialBook.title, directory: logsDirectory)
        defer { logger.close() }
        var settings = settingsStore.settings

        // Phase 1 "Einlesen" is visible immediately, while the heavy
        // preparation runs in the background.
        var initialProgress = RunProgress()
        initialProgress.phases = RunProgress.phases(hasImagePass: describesFigures(initialBook), hasSummary: initialBook.mode == .summary)
        initialProgress.stage = .extracting
        initialProgress.detail = "Buch wird eingelesen und analysiert …"
        progress[bookID] = initialProgress
        logger.onLine = { [weak self] message in
            Task { @MainActor in self?.updateProgress(bookID) { $0.appendLog(message) } }
        }
        logger.log("Einlesen: Abbildungen, Textumfang und Sprache werden ermittelt …")

        let snapshot = initialBook
        let analysis = await Task.detached(priority: .userInitiated) {
            PipelineController.analyze(snapshot, redetectLanguage: snapshot.languageOverride == nil)
        }.value
        if let language = analysis.detectedLanguage, language != initialBook.detectedLanguageCode {
            logger.log("Sprache neu erkannt: \(LanguageDetector.displayName(language)) (vorher \(initialBook.detectedLanguageCode.map(LanguageDetector.displayName) ?? "unbekannt")).")
            initialBook.detectedLanguageCode = language
            if var stored = libraryStore.book(id: bookID) {
                stored.detectedLanguageCode = language
                libraryStore.upsert(stored)
            }
        }
        logger.log("Sprache: \(LanguageDetector.displayName(initialBook.languageCode))\(initialBook.mode == .summary ? ", Zusammenfassung auf \(LanguageDetector.displayName(initialBook.outputLanguageCode))" : "").")

        updateProgress(bookID) { p in
            p.phases = RunProgress.phases(hasImagePass: self.describesFigures(initialBook) && analysis.hasFigures, hasSummary: initialBook.mode == .summary)
            p.plannedImages = self.describesFigures(initialBook) ? analysis.pendingFigureKeys : 0
            p.plannedSummaryCharacters = initialBook.mode == .summary ? analysis.sourceCharacters : 0
            // Measured: summaries keep ~35–60 % of the source.
            p.plannedNarrationCharacters = initialBook.mode == .summary ? Int(Double(analysis.sourceCharacters) * 0.5) : analysis.sourceCharacters
            p.charactersPerAudioSecond = 15 * max(initialBook.speechSpeed, 0.1)
            p.expectedRealTimeFactor = RunProgress.defaultRealTimeFactor(for: initialBook.engineID)
            p.defaultSecondsPerImage = 7 / Double(max(settings.visionParallelRequests, 1)) * 1.3
            p.phaseFraction = 1
        }

        do {
            var book = initialBook
            try Task.checkCancellation()

            // Transcription mode always reflects the true original document
            // structure — if a previous run already replaced `chapters` with
            // an AI-derived structure, restore the pristine snapshot first.
            if book.mode == .transcription, let sourceChapters = book.sourceChapters {
                book.chapters = sourceChapters
            }

            // Run image description pass if placeholders exist in the document
            await describeFigures(in: &book, logger: logger)
            if book.status == .paused {
                logger.log("Verarbeitung pausiert wegen nicht erreichbarem Bildpass-Server.")
                return
            }
            try Task.checkCancellation()
            libraryStore.upsert(book)

            if book.mode == .summary {
                let alreadySummarized = book.sourceChapters != nil && !book.chapters.isEmpty && book.chapters.allSatisfy { $0.summarizedText != nil }
                if !alreadySummarized {
                    book.currentStage = .summarizing
                    libraryStore.upsert(book)
                    enterStage(bookID, .summarizing, detail: "Verbinde mit \(settings.llmProvider.displayName) …")
                    logger.log("Modus: Zusammenfassung — prüfe LLM-Endpoint (\(settings.llmProvider.displayName), Modell \(settings.activeLLMModel)) …")
                    var client = SummarizerClient(settings: settings)
                    var connectionResult = await client.testConnection()
                    if case .failure = connectionResult, settings.autoStartOMLX && settings.llmProvider == .omlx {
                        logger.log("oMLX-Server läuft nicht. Versuche automatischen Start (autoStartOMLX aktiv) …")
                        if await OMLXLifecycleManager.startServer(timeout: 45) {
                            logger.log("oMLX-Server erfolgreich im Hintergrund gestartet.")
                            connectionResult = await client.testConnection()
                        } else {
                            logger.log("Automatischer Start von oMLX fehlgeschlagen.")
                        }
                    }
                    switch connectionResult {
                    case .failure(let error):
                        logger.log("LLM-Endpoint nicht erreichbar: \(error.localizedDescription)")
                        let errorMsg = "LLM-Endpoint nicht erreichbar (\(error.localizedDescription)). Bitte \(settings.llmProvider.displayName) starten oder im Transkriptions-Modus fortfahren."
                        book.status = .paused
                        book.lastErrorMessage = errorMsg
                        libraryStore.upsert(book)
                        return
                    case .success(let models):
                        // No model chosen yet (fresh oMLX setup): pick one once
                        // and remember it, instead of failing the run.
                        if settings.activeLLMModel.isEmpty, let preferred = LLMClient.preferredModel(from: models, hint: settings.llmModel) {
                            settingsStore.settings.activeLLMModel = preferred
                            settings = settingsStore.settings
                            client = SummarizerClient(settings: settings)
                            logger.log("Kein Modell eingestellt — verwende \(preferred).")
                        }
                        // Catch a stale model ID (model swapped/removed on the
                        // server) up front with a clear message instead of an
                        // opaque HTTP error from the first chat call.
                        if !models.isEmpty, !models.contains(settings.activeLLMModel) {
                            let message = "Modell „\(settings.activeLLMModel)“ ist bei \(settings.llmProvider.displayName) nicht verfügbar. Verfügbar: \(models.prefix(8).joined(separator: ", ")). Bitte unter Einstellungen → LLM ein Modell wählen."
                            logger.log(message)
                            book.status = .failed
                            book.lastErrorMessage = message
                            libraryStore.upsert(book)
                            return
                        }
                    }

                    // Snapshot the true original chapters exactly once — before
                    // `chapters` ever gets replaced by an AI-derived structure —
                    // so a later re-run always re-summarizes the real source
                    // text, never a previous AI restructuring.
                    if book.sourceChapters == nil {
                        book.sourceChapters = book.chapters
                    }
                    let sourceChapters = book.sourceChapters ?? book.chapters

                    for index in book.chapters.indices {
                        book.chapters[index].audioStatus = .summarizing
                    }
                    libraryStore.upsert(book)

                    let contextWindow = await LLMClient(settings: settings).activeContextWindow()
                    let budget = settings.effectiveSummarizationBudget(for: book.documentType, override: book.summarizationBudget, contextWindow: contextWindow)
                    let describeForSummary = describesFigures(book)
                    let removeReferencesForSummary = settingsStore.settings.removeCrossReferences
                    let summaryBoxLabelHandling = settings.boxLabelHandling
                    let summarySpeakHeadingNumbers = settings.speakHeadingNumbers
                    let summaryLanguageCode = book.outputLanguageCode
                    let inputs = await Task.detached(priority: .userInitiated) {
                        sourceChapters.map { chapter -> (title: String, text: String) in
                            var plain = chapter
                            plain.summarizedText = nil
                            return (chapter.title, PipelineController.narration(for: plain, describeFigures: describeForSummary, removeReferences: removeReferencesForSummary, boxLabelHandling: summaryBoxLabelHandling, speakHeadingNumbers: summarySpeakHeadingNumbers, languageCode: summaryLanguageCode))
                        }
                    }.value
                    logger.log("Fasse \(sourceChapters.count) Original-Kapitel zusammen (Dokumenttyp: \(book.documentType.displayName), Kontextfenster: \(contextWindow.map { "\($0) Tokens" } ?? "unbekannt"), Ziel-Budget ~\(budget / 1000)k Zeichen pro Aufruf) …")
                    let aiChapters = try await client.summarizeIntoChapters(
                        bookTitle: book.title,
                        chapters: inputs,
                        documentType: book.documentType,
                        characterBudget: budget,
                        contextWindow: contextWindow,
                        outputLanguage: book.summaryLanguageCode.map(LanguageDetector.englishName),
                        onProgress: { message in logger.log("  \(message)") },
                        onStructuredProgress: { [weak self] snapshot in
                            Task { @MainActor in
                                self?.updateProgress(bookID) {
                                    $0.llmCallsDone = snapshot.completedCalls
                                    $0.llmCallsTotal = snapshot.totalCalls
                                    $0.llmCharactersDone = snapshot.completedCharacters
                                    $0.llmCharactersTotal = snapshot.totalCharacters
                                    $0.llmTokensPerSecond = snapshot.lastTokensPerSecond ?? $0.llmTokensPerSecond
                                    $0.phaseFraction = snapshot.totalCharacters > 0 ? Double(snapshot.completedCharacters) / Double(snapshot.totalCharacters) : 0
                                    $0.detail = "LLM-Aufruf \(snapshot.completedCalls)/\(snapshot.totalCalls) fertig"
                                }
                            }
                        }
                    )

                    try Task.checkCancellation()
                    book.chapters = aiChapters.enumerated().map { index, result in
                        Chapter(title: result.title, groupTitle: result.groupTitle, rawText: result.sourceText, cleanedText: result.sourceText, summarizedText: result.summarizedText, order: index)
                    }
                    logger.log("Neue KI-Kapitelstruktur: \(book.chapters.count) Kapitel (aus \(sourceChapters.count) Original-Kapiteln).")
                    libraryStore.upsert(book)
                } else {
                    logger.log("Modus: Zusammenfassung — bereits zusammengefasst (\(book.chapters.count) Kapitel vorhanden). Fahre mit Synthese fort.")
                }
            }

            if settingsStore.settings.autoUnloadOMLXAfterPass && settingsStore.settings.llmProvider == .omlx {
                logger.log("Entlade oMLX-Server vor der Sprachsynthese, um Arbeitsspeicher freizugeben (autoUnloadOMLXAfterPass aktiv) …")
                let stopped = await OMLXLifecycleManager.stopServer(timeout: 15)
                if stopped {
                    logger.log("oMLX-Server erfolgreich beendet — Unified Memory freigegeben.")
                } else {
                    logger.log("oMLX-Server konnte nicht beendet werden (möglicherweise bereits beendet).")
                }
            }

            book.currentStage = .synthesizing
            libraryStore.upsert(book)

            let engine = TTSEngineFactory.engine(for: book.engineID, settings: settingsStore.settings)
            guard await engine.isReady(voice: book.voice) else {
                book.status = .failed
                book.lastErrorMessage = L("TTS-Engine ist nicht eingerichtet. Bitte unter Einstellungen → Engines & Downloads einrichten.")
                libraryStore.upsert(book)
                return
            }

            enterStage(bookID, .synthesizing)
            // Narration text of every chapter, prepared once in the background.
            let chaptersSnapshot = book.chapters
            let describe = describesFigures(book)
            let removeReferences = settingsStore.settings.removeCrossReferences
            let synthesisBoxLabelHandling = settingsStore.settings.boxLabelHandling
            let synthesisSpeakHeadingNumbers = settingsStore.settings.speakHeadingNumbers
            let synthesisLanguageCode = book.outputLanguageCode
            let narrationTexts = await Task.detached(priority: .userInitiated) {
                chaptersSnapshot.map { PipelineController.narration(for: $0, describeFigures: describe, removeReferences: removeReferences, boxLabelHandling: synthesisBoxLabelHandling, speakHeadingNumbers: synthesisSpeakHeadingNumbers, languageCode: synthesisLanguageCode) }
            }.value
            try Task.checkCancellation()
            let chapterLengths = narrationTexts.map(\.count)
            let totalCharacters = chapterLengths.reduce(0, +)
            let synthesisStart = Date()

            var chapterAudioFiles: [ChapterAudioFile] = []
            var alreadyDoneIndices: Set<Int> = []
            var initialFinishedSeconds: Double = 0.0

            for index in book.chapters.indices {
                let chapter = book.chapters[index]
                guard isIncludedInNarration(chapter) else { continue }
                let fileURL = chapter.audioFileURL ?? ChapterAudioStore.chapterFileURL(bookID: bookID, order: chapter.order, format: book.outputFormat, root: chapterAudioRoot)
                if chapter.audioStatus == .ready && FileManager.default.fileExists(atPath: fileURL.path) {
                    alreadyDoneIndices.insert(index)
                    let dur = chapter.audioDurationSeconds ?? 0
                    initialFinishedSeconds += dur
                    chapterAudioFiles.append(ChapterAudioFile(chapter: chapter, url: fileURL))
                }
            }

            updateProgress(bookID) {
                $0.chapterCount = chapterLengths.count
                $0.chaptersCompleted = alreadyDoneIndices.count
                $0.chapterCharacterCounts = chapterLengths
                $0.charactersPerAudioSecond = 15 * max(book.speechSpeed, 0.1)
                $0.finishedAudioSeconds = initialFinishedSeconds
                if totalCharacters > 0 && !alreadyDoneIndices.isEmpty {
                    let finishedChars = alreadyDoneIndices.reduce(0) { $0 + chapterLengths[$1] }
                    $0.phaseFraction = Double(finishedChars) / Double(totalCharacters)
                }
            }

            let pendingIndices = book.chapters.indices.filter { !alreadyDoneIndices.contains($0) && isIncludedInNarration(book.chapters[$0]) }
            if pendingIndices.isEmpty {
                logger.log("Alle \(book.chapters.count) Kapitel sind bereits synthetisiert. Fahre mit Verpackung fort.")
            } else {
                // Energy profile (v3.2): adapter/battery decides how many
                // chapters render at once.
                let parallelWorkers = PowerProfile.current.ttsWorkers(userSetting: settings.ttsWorkers(for: book.engineID))
                logger.log("Synthese: \(book.chapters.count) Kapitel insgesamt, \(alreadyDoneIndices.count) bereits fertig, \(pendingIndices.count) zu synthetisieren (\(parallelWorkers) parallele Worker).")
                if book.engineID == .phonon,
                   PhononEngine.usesNeuralEngine(profile: PowerProfile.current, speed: book.speechSpeed,
                                                 temperature: settings.phononTemperature, refinementSteps: settings.phononRefinementSteps,
                                                 neuralReady: PhononEnvironmentManager.shared.isNeuralReady(
                                                    PhononEnvironmentManager.modelKey(language: PhononEngine.split(book.voice).language, english31m: settings.phononEnglish31m))) {
                    logger.log("Phonon spricht über die Neural Engine (Energiemodus Stromsparend).")
                }

                let pendingItems: [PendingSynthesisItem] = pendingIndices.map { idx in
                    let c = book.chapters[idx]
                    return PendingSynthesisItem(
                        index: idx,
                        order: c.order,
                        title: c.title,
                        text: narrationTexts[idx],
                        outputURL: ChapterAudioStore.chapterFileURL(bookID: bookID, order: c.order, format: book.outputFormat, root: chapterAudioRoot)
                    )
                }

                // v4.1: MP3 chapters get their final ID3 tags on this first
                // encode, so packaging can move them instead of copying.
                var taggedURLs: [URL] = []
                if book.outputFormat == .mp3Chapters {
                    let tags = ChapterAudioTags.tags(for: book, narrated: book.chapters.filter { isIncludedInNarration($0) })
                    var map: [URL: ChapterTag] = [:]
                    for item in pendingItems {
                        if let tag = tags[book.chapters[item.index].id] { map[item.outputURL] = tag }
                    }
                    ChapterAudioTags.register(map)
                    taggedURLs = Array(map.keys)
                }
                defer { ChapterAudioTags.unregister(taggedURLs) }

                let totalChapters = book.chapters.count
                let voice = book.voice
                let speed = book.speechSpeed
                let qualitySettings = settings

                try ChapterAudioStore.prepareChapterAudioDirectory(bookID: bookID, root: chapterAudioRoot)

                var watchdogTask: Task<Void, Never>?
                if settings.ramWatchdogEnabled {
                    let limitMB = settings.effectiveRAMLimitMB(for: engine.id, workers: parallelWorkers)
                    let modeStr = settings.ramWatchdogAuto ? "Auto" : "Manuell"
                    logger.log("RAM-Watchdog aktiv (\(limitMB / 1024) GB Limit, Modus: \(modeStr)).")
                    watchdogTask = RAMWatchdog.startMonitoring(limitMB: limitMB) { [weak self] currentMB, maxMB in
                        guard let self else { return }
                        let msg = "RAM-Watchdog ausgelöst: Speicherverbrauch (\(Int(currentMB)) MB) hat das Limit von \(maxMB / 1024) GB überschritten. Synthese pausiert."
                        Task { @MainActor in
                            self.ramWatchdogTriggered[bookID] = msg
                            self.pauseProcessing(bookID: bookID)
                        }
                    }
                }
                defer { watchdogTask?.cancel() }

                try await withThrowingTaskGroup(of: ChapterSynthesisResult.self) { group in
                    var nextIndex = 0
                    var completedCount = alreadyDoneIndices.count

                    while nextIndex < pendingItems.count && nextIndex < parallelWorkers {
                        let item = pendingItems[nextIndex]
                        nextIndex += 1
                        await self.markChapterSynthesizing(bookID: bookID, index: item.index, completedCount: completedCount, chaptersCount: totalChapters)
                        logger.log("Starte Kapitel \(item.index + 1)/\(totalChapters): „\(item.title)“")
                        group.addTask {
                            try Task.checkCancellation()
                            let result = try await engine.synthesize(
                                text: item.text,
                                voice: voice,
                                speed: speed,
                                outputURL: item.outputURL,
                                onProgress: { event in
                                    if case .segmentDone(let segIdx, let duration) = event {
                                        logger.log("  Kapitel \(item.index + 1), Segment \(segIdx + 1) fertig (\(String(format: "%.1f", duration)) s Audio)")
                                    }
                                    Task { @MainActor in
                                        self.reportSegmentEvent(bookID: bookID, chapterIndex: item.index, event: event, totalCharacters: totalCharacters)
                                    }
                                }
                            )
                            await ChapterQualityReport.check(result.audioFileURL, chapter: "Kapitel \(item.index + 1)", settings: qualitySettings, logger: logger)
                            return ChapterSynthesisResult(index: item.index, result: result)
                        }
                    }

                    while let item = try await group.next() {
                        try Task.checkCancellation()
                        completedCount += 1
                        if let audioFile = await self.recordChapterDone(
                            bookID: bookID,
                            index: item.index,
                            result: item.result,
                            synthesisStart: synthesisStart,
                            totalCharacters: totalCharacters,
                            chapterLengths: chapterLengths,
                            completedCount: completedCount,
                            chaptersCount: totalChapters
                        ) {
                            chapterAudioFiles.append(audioFile)
                            logger.log("[\(completedCount)/\(totalChapters)] Kapitel fertig: „\(audioFile.chapter.title)“ (\(String(format: "%.1f", item.result.durationSeconds)) s Audio)")
                        }

                        if nextIndex < pendingItems.count {
                            let nextItem = pendingItems[nextIndex]
                            nextIndex += 1
                            await self.markChapterSynthesizing(bookID: bookID, index: nextItem.index, completedCount: completedCount, chaptersCount: totalChapters)
                            logger.log("Starte Kapitel \(nextItem.index + 1)/\(totalChapters): „\(nextItem.title)“")
                            group.addTask {
                                try Task.checkCancellation()
                                let result = try await engine.synthesize(
                                    text: nextItem.text,
                                    voice: voice,
                                    speed: speed,
                                    outputURL: nextItem.outputURL,
                                    onProgress: { event in
                                        if case .segmentDone(let segIdx, let duration) = event {
                                            logger.log("  Kapitel \(nextItem.index + 1), Segment \(segIdx + 1) fertig (\(String(format: "%.1f", duration)) s Audio)")
                                        }
                                        Task { @MainActor in
                                            self.reportSegmentEvent(bookID: bookID, chapterIndex: nextItem.index, event: event, totalCharacters: totalCharacters)
                                        }
                                    }
                                )
                                await ChapterQualityReport.check(result.audioFileURL, chapter: "Kapitel \(nextItem.index + 1)", settings: qualitySettings, logger: logger)
                                return ChapterSynthesisResult(index: nextItem.index, result: result)
                            }
                        }
                    }
                }
            }

            if let refreshed = libraryStore.book(id: bookID) {
                book = refreshed
            }

            chapterAudioFiles.sort { $0.chapter.order < $1.chapter.order }

            book.currentStage = .packaging
            libraryStore.upsert(book)
            enterStage(bookID, .packaging, detail: book.outputFormat.displayName)
            logger.log("Verpacke Ausgabe im Format \(book.outputFormat.displayName) …")

            let outputDirectory = OutputPathResolver.resolveOutputDirectory(book: book, settings: settingsStore.settings)
            let packager = ChapterPackagerFactory.packager(for: book.outputFormat, settings: settingsStore.settings)
            let finalURL = try await packager.package(
                book: book,
                chapterAudioFiles: chapterAudioFiles,
                outputDirectory: outputDirectory,
                onProgress: { message in logger.log("  \(message)") }
            )

            book.outputDirectoryURL = finalURL.hasDirectoryPath ? finalURL : finalURL.deletingLastPathComponent()

            // Post-packaging (plan 5.2): verify the output, then delete the
            // intermediate chapter audio (unless the user keeps it). The
            // player then streams from the packaged file.
            let keepChapterAudio = settingsStore.settings.keepChapterAudioAfterPackaging
            if book.outputFormat == .mp3Chapters {
                let directory = finalURL.hasDirectoryPath ? finalURL : finalURL.deletingLastPathComponent()
                let mp3Result = await ChapterAudioCleanup.finalizeMP3Chapters(
                    book: book,
                    outputDirectory: directory,
                    chapterAudioFiles: chapterAudioFiles,
                    keepChapterAudio: keepChapterAudio,
                    chapterAudioRoot: chapterAudioRoot
                )
                book = mp3Result.book
                mp3Result.messages.forEach { logger.log("  \($0)") }
            } else if let ffmpeg = await FFmpegLocator.resolveAsync(settings: settingsStore.settings) {
                let cleanupResult = await ChapterAudioCleanup.finalizeSingleFile(
                    book: book,
                    packagedURL: finalURL,
                    chapterAudioFiles: chapterAudioFiles,
                    ffmpeg: ffmpeg,
                    keepChapterAudio: keepChapterAudio,
                    chapterAudioRoot: chapterAudioRoot
                )
                book = cleanupResult.book
                cleanupResult.messages.forEach { logger.log("  \($0)") }
            }

            enterStage(bookID, .done)
            book.currentStage = .done
            book.status = .completed
            book.logFileURL = logger.fileURL
            libraryStore.upsert(book)
            logger.log("=== Fertig. Ausgabe: \(finalURL.path) ===")
            NotificationCenter.default.post(name: .audiobookCompleted, object: bookID)
        } catch is CancellationError {
            let wasPaused = pausedBookIDs.remove(bookID) != nil
            let watchdogMessage = ramWatchdogTriggered.removeValue(forKey: bookID)
            if let watchdogMessage {
                logger.log("⚠️ \(watchdogMessage)")
            } else {
                logger.log(wasPaused ? "Verarbeitung pausiert." : "Verarbeitung abgebrochen.")
            }
            if var book = libraryStore.book(id: bookID) {
                book.status = (wasPaused || watchdogMessage != nil) ? .paused : .needsReview
                if let watchdogMessage {
                    book.lastErrorMessage = watchdogMessage
                } else if !wasPaused {
                    resetBookAudioState(&book)
                }
                libraryStore.upsert(book)
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Pausing mid-LLM-call cancels the URLSession request first —
            // that surfaces as URLError.cancelled, not CancellationError,
            // and used to mark the book as failed instead of paused.
            let wasPaused = pausedBookIDs.remove(bookID) != nil
            let watchdogMessage = ramWatchdogTriggered.removeValue(forKey: bookID)
            if let watchdogMessage {
                logger.log("⚠️ \(watchdogMessage)")
            } else {
                logger.log(wasPaused ? "Verarbeitung pausiert." : "Verarbeitung abgebrochen.")
            }
            if var book = libraryStore.book(id: bookID) {
                book.status = (wasPaused || watchdogMessage != nil) ? .paused : .needsReview
                if let watchdogMessage {
                    book.lastErrorMessage = watchdogMessage
                } else if !wasPaused {
                    resetBookAudioState(&book)
                }
                libraryStore.upsert(book)
            }
        } catch {
            logger.log("Fehlgeschlagen: \(error.localizedDescription)")
            if var book = libraryStore.book(id: bookID) {
                book.status = .failed
                book.lastErrorMessage = error.localizedDescription
                book.logFileURL = logger.fileURL
                libraryStore.upsert(book)
            }
        }
    }

    // MARK: - Single-chapter regeneration

    private func runSingleChapterRegeneration(bookID: UUID, chapterID: UUID) async {
        guard var book = libraryStore.book(id: bookID),
              let chapterIndex = book.chapters.firstIndex(where: { $0.id == chapterID }) else { return }

        let logger = RunLogger(bookID: bookID, bookTitle: book.title + " (Kapitel-Neugenerierung)", directory: logsDirectory)
        defer { logger.close() }


        do {
            // When the intermediate chapter audio was deleted after
            // packaging (plan 5.2), restore it losslessly from the
            // verified M4B/M4A in ONE ffmpeg segment pass — otherwise
            // re-packaging below would have nothing to work with.
            if book.packagedAudio != nil, book.outputFormat != .mp3Chapters,
               book.chapters.contains(where: { $0.audioStatus == .ready && $0.audioFileURL == nil }) {
                guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settingsStore.settings) else {
                    throw PackagerError.ffmpegNotFound
                }
                if let packaged = book.packagedAudio, let packagedURL = PlaybackSourceResolver.resolvePackagedURL(packaged) {
                    book = try await ChapterAudioStore.restoreChapterAudio(fromPackagedURL: packagedURL, book: book, ffmpeg: ffmpeg, root: chapterAudioRoot)
                    logger.log("Kapitel-Audio aus der verpackten Datei wiederhergestellt (ein ffmpeg-Durchlauf).")
                    libraryStore.upsert(book)
                } else {
                    logger.log("Fehler: Ausgabe nicht gefunden — Volume verbunden? Kapitel-Audio kann nicht wiederhergestellt werden.")
                    book.chapters[chapterIndex].audioStatus = .failed
                    book.chapters[chapterIndex].lastError = "Ausgabe nicht gefunden — Volume verbunden? Ordner im Player neu zuordnen."
                    libraryStore.upsert(book)
                    return
                }
            }

            let engine = TTSEngineFactory.engine(for: book.engineID, settings: settingsStore.settings)
            guard await engine.isReady(voice: book.voice) else {
                book.chapters[chapterIndex].audioStatus = .failed
                book.chapters[chapterIndex].lastError = "TTS-Engine ist nicht eingerichtet."
                libraryStore.upsert(book)
                return
            }

            book.chapters[chapterIndex].audioStatus = .synthesizing
            libraryStore.upsert(book)

            if progress[bookID] == nil {
                var regenerationProgress = RunProgress()
                regenerationProgress.phases = [RunProgress.PhaseInfo(stage: .synthesizing, weight: 1)]
                regenerationProgress.enterStage(.synthesizing, detail: "Kapitel wird neu erzeugt …")
                progress[bookID] = regenerationProgress
            }
            updateProgress(bookID) {
                $0.chapterCount = book.chapters.count
                $0.chaptersCompleted = max(0, book.chapters.filter { $0.audioStatus == .ready }.count - 1)
                $0.activeChapters[chapterIndex] = RunProgress.ChapterProgress(index: chapterIndex, title: book.chapters[chapterIndex].title)
            }

            let chapter = book.chapters[chapterIndex]
            try ChapterAudioStore.prepareChapterAudioDirectory(bookID: bookID, root: chapterAudioRoot)
            let outputURL = ChapterAudioStore.chapterFileURL(bookID: bookID, order: chapter.order, format: book.outputFormat, root: chapterAudioRoot)
            if book.outputFormat == .mp3Chapters,
               let tag = ChapterAudioTags.tags(for: book, narrated: book.chapters.filter { isIncludedInNarration($0) })[chapter.id] {
                ChapterAudioTags.register([outputURL: tag])
            }
            defer { ChapterAudioTags.unregister([outputURL]) }

            let result = try await engine.synthesize(
                text: narrationText(for: chapter, book: book),
                voice: book.voice,
                speed: book.speechSpeed,
                outputURL: outputURL,
                onProgress: { event in
                    if case .segmentDone(let index, let duration) = event {
                        logger.log("Segment \(index) fertig (\(String(format: "%.1f", duration))s)")
                    }
                    Task { @MainActor in
                        self.reportSegmentEvent(bookID: bookID, chapterIndex: chapterIndex, event: event, totalCharacters: 0)
                    }
                }
            )

            await ChapterQualityReport.check(result.audioFileURL, chapter: "Kapitel \(chapterIndex + 1)", settings: settingsStore.settings, logger: logger)
            book.chapters[chapterIndex].audioFileURL = result.audioFileURL
            book.chapters[chapterIndex].audioDurationSeconds = result.durationSeconds
            book.chapters[chapterIndex].audioSegments = result.segments
            book.chapters[chapterIndex].audioStatus = .ready
            libraryStore.upsert(book)
            updateProgress(bookID, immediate: true) { p in
                p.activeChapters[chapterIndex] = nil
                p.chaptersCompleted = max(0, book.chapters.filter { $0.audioStatus == .ready }.count - 1)
                p.phaseFraction = 1
                p.detail = "Kapitel neu erzeugt"
            }

            // Re-package so the exported file reflects the updated chapter.
            let readyChapterFiles = book.chapters
                .filter { $0.audioStatus == .ready }
                .compactMap { chapter -> ChapterAudioFile? in
                    guard let url = chapter.audioFileURL else { return nil }
                    return ChapterAudioFile(chapter: chapter, url: url)
                }

            guard readyChapterFiles.count == book.chapters.count else {
                logger.log("Nicht alle Kapitel haben Audio — überspringe Neuverpackung.")
                return
            }

            let outputDirectory = book.outputDirectoryURL ?? OutputPathResolver.resolveOutputDirectory(book: book, settings: settingsStore.settings)

            let packager = ChapterPackagerFactory.packager(for: book.outputFormat, settings: settingsStore.settings)
            let finalURL = try await packager.package(
                book: book,
                chapterAudioFiles: readyChapterFiles,
                outputDirectory: outputDirectory,
                onProgress: { message in logger.log(message) }
            )
            book.outputDirectoryURL = finalURL.hasDirectoryPath ? finalURL : finalURL.deletingLastPathComponent()

            // Same post-packaging rules as a full run (plan 5.2): verify,
            // then delete the (partly restored) chapter audio again when
            // the user doesn't keep it.
            let keepChapterAudio = settingsStore.settings.keepChapterAudioAfterPackaging
            let restoredFiles = book.sortedChapters.compactMap { chapter -> ChapterAudioFile? in
                guard let url = chapter.audioFileURL else { return nil }
                return ChapterAudioFile(chapter: chapter, url: url)
            }
            if book.outputFormat == .mp3Chapters {
                let directory = finalURL.hasDirectoryPath ? finalURL : finalURL.deletingLastPathComponent()
                let mp3Result = await ChapterAudioCleanup.finalizeMP3Chapters(
                    book: book,
                    outputDirectory: directory,
                    chapterAudioFiles: restoredFiles,
                    keepChapterAudio: keepChapterAudio,
                    chapterAudioRoot: chapterAudioRoot
                )
                book = mp3Result.book
                mp3Result.messages.forEach { logger.log($0) }
            } else if let ffmpeg = await FFmpegLocator.resolveAsync(settings: settingsStore.settings) {
                let cleanupResult = await ChapterAudioCleanup.finalizeSingleFile(
                    book: book,
                    packagedURL: finalURL,
                    chapterAudioFiles: restoredFiles,
                    ffmpeg: ffmpeg,
                    keepChapterAudio: keepChapterAudio,
                    chapterAudioRoot: chapterAudioRoot
                )
                book = cleanupResult.book
                cleanupResult.messages.forEach { logger.log($0) }
            }
            libraryStore.upsert(book)
        } catch {
            logger.log("Fehler bei Kapitel-Neugenerierung: \(error.localizedDescription)")
            let outputURL = ChapterAudioStore.chapterFileURL(bookID: bookID, order: book.chapters[chapterIndex].order, format: book.outputFormat, root: chapterAudioRoot)
            try? FileManager.default.removeItem(at: outputURL)
            book.chapters[chapterIndex].audioStatus = .failed
            book.chapters[chapterIndex].lastError = error.localizedDescription
            libraryStore.upsert(book)
        }
    }
}
