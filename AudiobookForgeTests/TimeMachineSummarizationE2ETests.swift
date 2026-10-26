import XCTest
import Foundation
@testable import AudiobookForge

@MainActor
final class TimeMachineSummarizationE2ETests: XCTestCase {
    func testEndToEndSummarizationAndTimeMachineAudiobook() async throws {
        try LiveTestGate.require("Time-Machine-E2E (oMLX)")
        // v4.1: own library, settings and output — the test once wrote into
        // the real library while the app was running and the book fell out
        // of the app's index.
        let scratch = try LiveTestGate.scratchDirectory("timemachine")
        guard let fixturesDir = ProcessInfo.processInfo.environment["AUDIOBOOKFORGE_SMOKE_FIXTURES_DIR"], !fixturesDir.isEmpty else {
            throw XCTSkip("Set AUDIOBOOKFORGE_SMOKE_FIXTURES_DIR to run Time Machine E2E test")
        }
        let epubURL = URL(fileURLWithPath: fixturesDir, isDirectory: true).appendingPathComponent("The_Time_Machine.epub")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: epubURL.path), "Test book not found at \(epubURL.path)")

        let settingsStore = SettingsStore(fileURL: scratch.appendingPathComponent("settings.json"))
        settingsStore.settings.llmProvider = .omlx
        settingsStore.settings.omlxBaseURL = "http://127.0.0.1:8000/v1"
        settingsStore.settings.omlxAPIKey = "admin"
        settingsStore.settings.omlxModel = "Qwen3.6-35B-A3B-oQ4e-mtp"
        settingsStore.settings.autoUnloadOMLXAfterPass = false
        settingsStore.settings.ttsEngine = .kokoro
        settingsStore.settings.kokoroVoice = "af_heart"
        settingsStore.settings.defaultVoiceEN = VoiceID(engine: .kokoro, voice: "af_heart")
        settingsStore.settings.defaultOutputFormat = .mp3Chapters
        settingsStore.settings.ttsParallelWorkers = 1
        settingsStore.settings.outputBaseFolderPath = scratch.appendingPathComponent("out", isDirectory: true).path

        let libraryStore = LibraryStore(root: scratch.appendingPathComponent("library", isDirectory: true))

        // Clean up any previous test run with this title
        for existing in libraryStore.books where existing.title == "The Time Machine (KI-Zusammenfassung)" {
            print(">>> Removing previous run of \(existing.title)...")
            libraryStore.remove(existing)
            ChapterAudioStore.removeChapterAudio(bookID: existing.id)
        }
        libraryStore.flush()

        print(">>> Importing The Time Machine from \(epubURL.lastPathComponent)...")
        var book = try await DocumentImportService.importDocument(at: epubURL, settings: settingsStore.settings)
        book.title = "The Time Machine (KI-Zusammenfassung)"
        book.mode = .summary
        book.engineID = .kokoro
        book.voice = "af_heart"
        book.documentType = .general
        book.outputFormat = .mp3Chapters
        book.summarizationBudget = 55000 // ~4 chunks for ~220k chars

        libraryStore.upsert(book)
        libraryStore.flush()
        let bookID = book.id

        print(">>> Imported book ID: \(bookID), source chapters: \(book.chapters.count)")

        let controller = PipelineController(
            libraryStore: libraryStore,
            settingsStore: settingsStore,
            chapterAudioRoot: scratch.appendingPathComponent("chapter_audio", isDirectory: true)
        )

        print(">>> Starting pipeline (Mode: Summary, Engine: Kokoro af_heart)...")
        controller.enqueue(bookID: bookID)

        var lastStage: PipelineStage? = nil
        var lastDetail: String = ""
        let startTime = Date()

        while controller.isAnyBookActive {
            try await Task.sleep(for: .milliseconds(1000))
            if let p = controller.progress[bookID] {
                let stage = p.stage
                let detail = p.detail
                if stage != lastStage || detail != lastDetail {
                    let elapsed = Int(Date().timeIntervalSince(startTime))
                    print("[\(elapsed)s] Stage: \(stage.rawValue) | \(detail) | Overall: \(Int(p.overallFraction * 100))%")
                    lastStage = stage
                    lastDetail = detail
                }
            }
        }

        print(">>> Pipeline completed in \(Int(Date().timeIntervalSince(startTime)))s")

        // Reload the book from store
        guard let completedBook = libraryStore.book(id: bookID) else {
            XCTFail("Completed book could not be reloaded from library store")
            return
        }

        print("================================================================================")
        print("AUDIOBOOK STATUS: \(completedBook.status.rawValue)")
        if let err = completedBook.lastErrorMessage {
            print("ERROR MESSAGE: \(err)")
        }
        XCTAssertEqual(completedBook.status, .completed, "Pipeline must finish with status completed: \(completedBook.lastErrorMessage ?? "none")")

        print("AI Chapters produced: \(completedBook.chapters.count) (from \(completedBook.sourceChapters?.count ?? 0) source chapters)")
        XCTAssertGreaterThan(completedBook.chapters.count, 0, "Book must have at least one AI chapter")

        var totalSourceChars = 0
        var totalSummarizedChars = 0
        var totalAudioSeconds: Double = 0

        for (idx, ch) in completedBook.chapters.enumerated() {
            print("--------------------------------------------------------------------------------")
            print("CHAPTER \(idx + 1): \(ch.title)")
            print("Source Text Length: \(ch.cleanedText.count) chars")
            totalSourceChars += ch.cleanedText.count

            if let summary = ch.summarizedText {
                totalSummarizedChars += summary.count
                print("Summarized Text Length: \(summary.count) chars")
                print("--- SUMMARY EXCERPT (first 400 chars) ---")
                print(String(summary.prefix(400)))
                print("--- END EXCERPT ---")
            } else {
                XCTFail("Chapter \(idx + 1) is missing summarizedText!")
            }

            if let dur = ch.audioDurationSeconds {
                totalAudioSeconds += dur
                print("Audio Duration: \(String(format: "%.1f", dur))s (\(String(format: "%.1f", dur / 60.0)) min)")
            } else {
                print("Audio Duration: missing")
            }

            if let audioURL = ch.audioFileURL {
                print("Audio File URL: \(audioURL.path)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Audio file must exist at \(audioURL.path)")
            } else {
                XCTFail("Chapter \(idx + 1) has no audioFileURL!")
            }
        }

        print("================================================================================")
        print("TOTAL EVALUATION SUMMARY:")
        print("Original Source Chars: \(totalSourceChars)")
        print("Summarized Chars:      \(totalSummarizedChars)")
        let ratio = totalSourceChars > 0 ? (Double(totalSummarizedChars) / Double(totalSourceChars)) * 100.0 : 0
        print("Compression Ratio:     \(String(format: "%.1f", ratio))% of original length")
        print("Total Audio Length:    \(String(format: "%.1f", totalAudioSeconds / 60.0)) minutes (\(String(format: "%.0f", totalAudioSeconds)) seconds)")
        print("================================================================================")
    }
}
