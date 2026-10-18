import Foundation
import XCTest
@testable import AudiobookForge

/// Real run on a figure-heavy textbook chapter: vision descriptions via
/// oMLX inserted at the figure positions, German narration, M4B — then the
/// same chapter summarized with the short descriptions. Opt-in:
///   TEST_RUNNER_ABF_E2E_OMLX_URL, TEST_RUNNER_ABF_E2E_MODEL,
///   TEST_RUNNER_ABF_FIG_PDF, TEST_RUNNER_ABF_FIG_MARKER (text inside the chapter),
///   TEST_RUNNER_ABF_E2E_OUTPUT (optional)
@MainActor
final class RealFigureTests: XCTestCase {
    func testTextbookChapterWithFiguresTranscriptionThenSummary() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let baseURL = env["ABF_E2E_OMLX_URL"], let model = env["ABF_E2E_MODEL"], let pdf = env["ABF_FIG_PDF"] else {
            throw XCTSkip("ABF_* environment not set")
        }
        let marker = env["ABF_FIG_MARKER"] ?? "Abb. 6.8"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("abf-fig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let outputBase = env["ABF_E2E_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? work.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)

        let settingsStore = SettingsStore(fileURL: work.appendingPathComponent("settings.json"))
        var settings = AppSettings()
        settings.llmProvider = .omlx
        settings.omlxBaseURL = baseURL
        settings.omlxModel = model
        settings.describeImagesWithVisionModel = true
        settings.visionParallelRequests = 2
        settings.outputBaseFolderPath = outputBase.path
        settingsStore.settings = settings
        let libraryStore = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        let controller = PipelineController(libraryStore: libraryStore, settingsStore: settingsStore)

        var book = try await DocumentImportService.importDocument(at: URL(fileURLWithPath: pdf), settings: settings)
        guard let chapter = book.chapters.first(where: { $0.cleanedText.contains(marker) }) else {
            return XCTFail("no chapter contains \(marker)")
        }
        var single = chapter
        single.order = 0
        book.chapters = [single]
        book.title = "Abbildungstest \(chapter.title)"
        book.mode = .transcription
        book.engineID = .kokoroGerman
        book.voice = "martin"
        book.speechSpeed = 1.0
        book.outputFormat = .m4b
        libraryStore.upsert(book)
        defer { try? FileManager.default.removeItem(at: AppPaths.chapterAudioDirectory(bookID: book.id)) }
        let figureCount = ImageDescriptionMarker.figures(in: single.cleanedText).count
        XCTAssertGreaterThan(figureCount, 0)

        // Run 1: transcription with full descriptions.
        var stages: [PipelineStage] = []
        var etas: [Double] = []
        let started = Date()
        controller.enqueue(bookID: book.id)
        while controller.isRunning(book.id) {
            if let p = controller.progress[book.id] {
                if stages.last != p.stage { stages.append(p.stage) }
                if let eta = p.estimatedTotalRemainingSeconds { etas.append(eta) }
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        let firstRun = Date().timeIntervalSince(started)
        let transcribed = try XCTUnwrap(libraryStore.book(id: book.id))
        XCTAssertEqual(transcribed.status, .completed, transcribed.lastErrorMessage ?? "")
        XCTAssertTrue(stages.contains(.describingImages), "\(stages)")
        XCTAssertFalse(etas.isEmpty, "whole-book ETA was shown")
        let stored = transcribed.chapters[0].cleanedText
        let described = ImageDescriptionMarker.figures(in: stored).filter { $0.existing == .full }
        XCTAssertGreaterThan(described.count, 0, "at least one figure described")
        let narration = ImageDescriptionMarker.unwrap(stored)
        XCTAssertTrue(narration.contains("Abbildung: "))
        // The description of the captioned figure follows its caption.
        if let captionRange = narration.range(of: marker) {
            let after = narration[captionRange.upperBound...]
            let nextDescription = after.range(of: "Abbildung: ")
            let nextHeading = after.range(of: "\n\n")
            XCTAssertNotNil(nextDescription)
            if let nextDescription, let nextHeading { XCTAssertGreaterThan(nextDescription.lowerBound, nextHeading.lowerBound, "description is its own paragraph") }
        }

        // Run 2: summary mode — short descriptions, the model decides.
        var summaryBook = transcribed
        summaryBook.mode = .summary
        summaryBook.documentType = .book
        summaryBook.status = .needsReview
        libraryStore.upsert(summaryBook)
        let secondStart = Date()
        controller.enqueue(bookID: book.id)
        while controller.isRunning(book.id) { try await Task.sleep(for: .milliseconds(300)) }
        let secondRun = Date().timeIntervalSince(secondStart)
        let summarized = try XCTUnwrap(libraryStore.book(id: book.id))
        XCTAssertEqual(summarized.status, .completed, summarized.lastErrorMessage ?? "")
        let sources = try XCTUnwrap(summarized.sourceChapters)
        XCTAssertTrue(ImageDescriptionMarker.figures(in: sources[0].cleanedText).contains { $0.existing == .short })
        let summaryText = summarized.chapters.compactMap(\.summarizedText).joined(separator: "\n\n")
        XCTAssertFalse(summaryText.isEmpty)
        XCTAssertFalse(summaryText.contains("\u{2063}"), "no internal markers reach the summary")

        let log = (try? String(contentsOf: try XCTUnwrap(summarized.logFileURL), encoding: .utf8)) ?? ""
        let firstLog = try String(contentsOf: try XCTUnwrap(transcribed.logFileURL), encoding: .utf8)
        let report = """
        FIGURE_REPORT chapter=\(chapter.title) figures=\(figureCount) described=\(described.count)
        run1_transcription=\(Int(firstRun))s stages=\(stages.map(\.rawValue)) eta_first=\(etas.first.map { Int($0) } ?? -1)s
        run2_summary=\(Int(secondRun))s ai_chapters=\(summarized.chapters.count)
        --- narration excerpt ---
        \(narration.range(of: marker).map { String(narration[$0.lowerBound...].prefix(1600)) } ?? String(narration.prefix(1600)))
        --- summary excerpt ---
        \(summaryText.prefix(2500))
        --- log run 1 ---
        \(firstLog.components(separatedBy: "\n").filter { $0.contains("Bild") || $0.contains("→") || $0.contains("Abbildung") }.joined(separator: "\n"))
        --- log run 2 ---
        \(log.components(separatedBy: "\n").filter { $0.contains("Bild") || $0.contains("→") || $0.contains("Antwort") }.joined(separator: "\n"))
        """
        try report.write(to: outputBase.appendingPathComponent("abbildungstest-report.txt"), atomically: true, encoding: .utf8)
        print(report)
    }
}
