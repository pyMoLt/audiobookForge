import XCTest
@testable import AudiobookForge

/// Deterministic TTS engine for pause/resume tests: produces a real
/// (tiny, silent) AAC file via ffmpeg so packaging works, but only when
/// its gate allows it — otherwise `synthesize` waits, which lets tests
/// pause/cancel the pipeline mid-synthesis.
final class FakeTTSEngine: TTSEngine, @unchecked Sendable {
    let id: TTSEngineID = .kokoro
    let synthesizeCalls: LockedBox<[String]> = LockedBox([])
    /// Number of `synthesize` calls allowed to proceed immediately; every
    /// further call waits until `openGate()` (tests control pacing).
    private let proceedAllowance: LockedBox<Int>
    private let gateOpened = LockedBox(false)

    init(proceedAllowance: Int) {
        self.proceedAllowance = LockedBox(proceedAllowance)
    }

    func openGate() {
        gateOpened.withLock { $0 = true }
    }

    func availableVoices() -> [TTSVoiceOption] {
        [TTSVoiceOption(id: "fake", displayName: "Fake Stimme")]
    }

    func isReady() async -> Bool { true }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        synthesizeCalls.withLock { $0.append(text) }
        let started = Date()
        while !Task.isCancelled {
            if gateOpened.withLock({ $0 }) { break }
            if proceedAllowance.withLock({ $0 }) > 0 {
                proceedAllowance.withLock { $0 -= 1 }
                break
            }
            if Date().timeIntervalSince(started) > 20 { break } // safety valve
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()

        guard let ffmpeg = FFmpegLocator.resolve(settings: AppSettings()) else {
            throw XCTSkip("ffmpeg fehlt")
        }
        try await FFmpegRunner.run(
            executable: ffmpeg,
            arguments: ["-y", "-hide_banner", "-loglevel", "error",
                        "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono", "-t", "0.2",
                        "-c:a", "aac", outputURL.path]
        )
        onProgress(.plannedSegments(1))
        onProgress(.segmentDone(index: 0, durationSeconds: 0.2))
        return TTSSynthesisResult(
            audioFileURL: outputURL,
            durationSeconds: 0.2,
            segmentCount: 1,
            segments: [TTSSegment(index: 0, startSeconds: 0, durationSeconds: 0.2, text: nil)]
        )
    }
}

/// Phase 1 (4.3): every edge of the pause/resume/cancel state machine,
/// driven through the real `PipelineController` with a fake engine and a
/// stub LLM — no bridge, no model, no real LLM endpoint.
@MainActor
final class PauseResumeTests: XCTestCase {
    private var work: URL!
    private var store: LibraryStore!
    private var settingsStore: SettingsStore!
    private var pipeline: PipelineController!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("chapter_audio"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("logs"), withIntermediateDirectories: true)

        store = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        settingsStore = SettingsStore(fileURL: work.appendingPathComponent("settings.json"))
        var settings = settingsStore.settings
        settings.describeImagesWithVisionModel = false
        settings.ttsParallelWorkers = 1
        settings.autoStartOMLX = false
        settings.autoUnloadOMLXAfterPass = false
        settings.outputBaseFolderPath = work.appendingPathComponent("output").path
        settingsStore.settings = settings

        pipeline = PipelineController(
            libraryStore: store,
            settingsStore: settingsStore,
            chapterAudioRoot: work.appendingPathComponent("chapter_audio"),
            logsDirectory: work.appendingPathComponent("logs")
        )
    }

    override func tearDownWithError() throws {
        TTSEngineFactory.engineOverride = nil
        URLProtocol.unregisterClass(StubLLMProtocol.self)
        StubLLMProtocol.handler = nil
        try? FileManager.default.removeItem(at: work)
    }

    private func makeBook(title: String, chapterTexts: [String], mode: ProcessingMode = .transcription) -> BookProject {
        var book = BookProject(
            title: title, author: "Test", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            chapters: chapterTexts.enumerated().map { index, text in
                Chapter(title: "Kapitel \(index + 1)", rawText: text, cleanedText: text, order: index)
            },
            outputFormat: .m4b, voice: "fake", speechSpeed: 1.0
        )
        book.mode = mode
        book.engineID = .kokoro
        return book
    }

    @discardableResult
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 15,
        _ message: String = "condition"
    ) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// Edge: pause while a chapter is synthesizing → book becomes
    /// .paused, nothing is marked failed, resume finishes the run.
    func testPauseDuringSynthesisPausesAndResumeCompletes() async throws {
        guard FFmpegLocator.resolve(settings: AppSettings()) != nil else { throw XCTSkip("ffmpeg fehlt") }
        let engine = FakeTTSEngine(proceedAllowance: 0)
        TTSEngineFactory.engineOverride = { _ in engine }

        let book = makeBook(title: "Pause-Synthese", chapterTexts: ["Erstes Kapitel. Mehr Text.", "Zweites Kapitel. Mehr Text."])
        store.upsert(book)
        pipeline.enqueue(bookID: book.id)

        let synthesizing = await waitFor { [weak self] in
            self?.pipeline.progress[book.id]?.stage == .synthesizing && !(engine.synthesizeCalls.withLock { $0 }.isEmpty)
        }
        XCTAssertTrue(synthesizing, "engine never started synthesizing")

        pipeline.pauseProcessing(bookID: book.id)
        let paused = await waitFor { [weak self] in
            self?.store.book(id: book.id)?.status == .paused
        }
        XCTAssertTrue(paused, "book should be paused after pausing mid-synthesis")
        XCTAssertNil(pipeline.progress[book.id], "progress entry must be cleaned up after the run unwound")
        XCTAssertEqual(pipeline.activeBookID, nil)

        engine.openGate()
        pipeline.resumeProcessing(bookID: book.id)
        let completed = await waitFor { [weak self] in
            self?.store.book(id: book.id)?.status == .completed
        }
        XCTAssertTrue(completed, "resumed run should complete")
        XCTAssertGreaterThan(engine.synthesizeCalls.withLock { $0 }.count, 1, "resume must re-synthesize unfinished chapters")
    }

    /// Edge: cancel after pause → book returns to .needsReview and its
    /// intermediate chapter audio is cleaned up.
    func testCancelAfterPauseResetsToNeedsReview() async throws {
        guard FFmpegLocator.resolve(settings: AppSettings()) != nil else { throw XCTSkip("ffmpeg fehlt") }
        let engine = FakeTTSEngine(proceedAllowance: 1) // chapter 1 finishes, chapter 2 blocks
        TTSEngineFactory.engineOverride = { _ in engine }

        let book = makeBook(title: "Cancel-nach-Pause", chapterTexts: ["Kapitel eins.", "Kapitel zwei."])
        store.upsert(book)
        pipeline.enqueue(bookID: book.id)

        let blocked = await waitFor { engine.synthesizeCalls.withLock { $0 }.count >= 2 }
        XCTAssertTrue(blocked, "second chapter never started")

        pipeline.pauseProcessing(bookID: book.id)
        let paused = await waitFor { [weak self] in self?.store.book(id: book.id)?.status == .paused }
        XCTAssertTrue(paused)

        pipeline.cancelProcessing(bookID: book.id)
        let cancelled = await waitFor { [weak self] in self?.store.book(id: book.id)?.status == .needsReview }
        XCTAssertTrue(cancelled, "cancel after pause must return to review, not stay paused")
        let reloaded = store.book(id: book.id)!
        XCTAssertTrue(reloaded.chapters.allSatisfy { $0.audioStatus == .pending && $0.audioFileURL == nil },
                      "cancel must reset chapter audio state")
        let audioDir = work.appendingPathComponent("chapter_audio").appendingPathComponent(book.id.uuidString)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "cancel must delete intermediate chapter audio")
    }

    /// Edge: pausing a book that is still waiting in the queue.
    func testPauseQueuedBookDoesNotStartIt() async throws {
        guard FFmpegLocator.resolve(settings: AppSettings()) != nil else { throw XCTSkip("ffmpeg fehlt") }
        let engine = FakeTTSEngine(proceedAllowance: 0)
        TTSEngineFactory.engineOverride = { _ in engine }

        let active = makeBook(title: "Aktiv", chapterTexts: ["Läuft."])
        let queued = makeBook(title: "Wartend", chapterTexts: ["Wartet."])
        store.upsert(active)
        store.upsert(queued)
        pipeline.enqueue(bookID: active.id)
        pipeline.enqueue(bookID: queued.id)

        let queuedSeen = await waitFor { self.pipeline.isQueued(queued.id) }
        XCTAssertTrue(queuedSeen)

        pipeline.pauseProcessing(bookID: queued.id)
        XCTAssertEqual(store.book(id: queued.id)?.status, .paused, "queued book must be .paused immediately")
        XCTAssertFalse(pipeline.isQueued(queued.id), "paused book must leave the queue")

        engine.openGate()
        _ = await waitFor { self.store.book(id: active.id)?.status == .completed }
        XCTAssertEqual(store.book(id: queued.id)?.status, .paused, "queued book must not have started")
        XCTAssertTrue(engine.synthesizeCalls.withLock { $0 }.allSatisfy { !$0.contains("Wartet.") })
    }

    /// Edge: pause → app restart (fresh stores from disk) → resume skips
    /// chapters whose audio already exists and only synthesizes the rest.
    func testResumeAfterRestartSkipsFinishedChapters() async throws {
        guard FFmpegLocator.resolve(settings: AppSettings()) != nil else { throw XCTSkip("ffmpeg fehlt") }
        let engine = FakeTTSEngine(proceedAllowance: 1) // chapter 1 finishes, chapter 2 blocks
        TTSEngineFactory.engineOverride = { _ in engine }

        let book = makeBook(title: "Neustart", chapterTexts: ["Kapitel eins Text.", "Kapitel zwei Text."])
        store.upsert(book)
        store.flush()
        pipeline.enqueue(bookID: book.id)

        let firstDone = await waitFor { [weak self] in
            self?.store.book(id: book.id)?.chapters.first?.audioStatus == .ready
        }
        XCTAssertTrue(firstDone, "first chapter never finished")

        pipeline.pauseProcessing(bookID: book.id)
        let paused = await waitFor { [weak self] in self?.store.book(id: book.id)?.status == .paused }
        XCTAssertTrue(paused)
        store.flush()

        // Simulated app restart: fresh store + controller from disk,
        // same chapter-audio root (that is what survives a restart).
        let freshStore = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        let freshPipeline = PipelineController(
            libraryStore: freshStore,
            settingsStore: settingsStore,
            chapterAudioRoot: work.appendingPathComponent("chapter_audio"),
            logsDirectory: work.appendingPathComponent("logs")
        )
        let resumedEngine = FakeTTSEngine(proceedAllowance: 5)
        TTSEngineFactory.engineOverride = { _ in resumedEngine }

        freshPipeline.resumeProcessing(bookID: book.id)
        let completed = await waitFor { [weak freshStore] in
            freshStore?.book(id: book.id)?.status == .completed
        }
        XCTAssertTrue(completed, "resumed run after restart should complete")

        let calls = resumedEngine.synthesizeCalls.withLock { $0 }
        XCTAssertEqual(calls, ["Kapitel zwei Text."], "restart-resume must skip the already-synthesized chapter")
    }

    /// Edge: pause during summarization (stubbed LLM, slow response) →
    /// .paused (not .failed), resume completes the whole run.
    func testPauseDuringSummaryPausesNotFails() async throws {
        guard FFmpegLocator.resolve(settings: AppSettings()) != nil else { throw XCTSkip("ffmpeg fehlt") }
        URLProtocol.registerClass(StubLLMProtocol.self)
        StubLLMProtocol.handler = { prompt in
            (prompt.isEmpty ? "## Teil\nInhalt." : "## Teil\nZusammengefasster Inhalt.", "stop", 2.0)
        }
        var settings = settingsStore.settings
        settings.llmProvider = .omlx
        settings.omlxBaseURL = "http://stub.llm/v1"
        settings.omlxModel = "stub-model"
        settings.describeImagesWithVisionModel = false
        settingsStore.settings = settings

        let engine = FakeTTSEngine(proceedAllowance: 5)
        TTSEngineFactory.engineOverride = { _ in engine }

        let book = makeBook(title: "Pause-Zusammenfassung", chapterTexts: ["Langer Quelltext.", "Mehr Quelle."], mode: .summary)
        store.upsert(book)
        pipeline.enqueue(bookID: book.id)

        let summarizing = await waitFor { [weak self] in
            self?.pipeline.progress[book.id]?.stage == .summarizing
        }
        XCTAssertTrue(summarizing, "summary stage never started")
        try await Task.sleep(for: .milliseconds(300)) // mid-LLM-call

        pipeline.pauseProcessing(bookID: book.id)
        let paused = await waitFor { [weak self] in self?.store.book(id: book.id)?.status == .paused }
        XCTAssertTrue(paused, "pause during summary must pause the book, not fail it")
        XCTAssertNotEqual(store.book(id: book.id)?.status, BookProjectStatus.failed)

        StubLLMProtocol.handler = { _ in ("## Teil\nZusammengefasster Inhalt.", "stop", 0) }
        pipeline.resumeProcessing(bookID: book.id)
        let completed = await waitFor { [weak self] in self?.store.book(id: book.id)?.status == .completed }
        XCTAssertTrue(completed, "resumed summary run should complete")
    }
}
