import XCTest
import Foundation
@testable import AudiobookForge

@MainActor
final class ChristmasCarolResynthesisTests: XCTestCase {
    func testResynthesizeChapters2And7WithWatchdog() async throws {
        let bookID = UUID(uuidString: "D4498694-419F-4EB7-9EF5-4B01CE083D8C")!
        let libraryStore = LibraryStore()
        guard let initialBook = libraryStore.book(id: bookID) else {
            XCTFail("Christmas Carol book not found in library")
            return
        }

        let settingsStore = SettingsStore()
        settingsStore.settings.ttsParallelWorkers = 1
        settingsStore.settings.ttsEngine = .kokoro
        settingsStore.settings.kokoroVoice = "af_heart"

        let controller = PipelineController(
            libraryStore: libraryStore,
            settingsStore: settingsStore
        )

        // Engine-aware memory watchdog
        let watchdogTask = Task.detached {
            while !Task.isCancelled {
                let totalMB = RAMWatchdog.totalResidentMB()
                if totalMB > 12000.0 {
                    fatalError("MEMORY WATCHDOG TRIGGERED: Total process tree RSS \(totalMB) MB exceeded 12 GB!")
                }
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
        defer { watchdogTask.cancel() }

        // 1. Check or synthesize Chapter 2 (idx 1: "MARLEY’S GHOST.")
        let ch2ID = initialBook.chapters[1].id
        let initialCh2Segs = initialBook.chapters[1].audioSegments ?? []
        let initialCh2Text = initialCh2Segs.filter { $0.text != nil && !$0.text!.isEmpty }
        if initialCh2Segs.isEmpty || initialCh2Text.count != initialCh2Segs.count {
            print(">>> STARTING SYNTHESIS OF CHAPTER 2 (\(initialBook.chapters[1].title))...")
            controller.regenerateChapter(bookID: bookID, chapterID: ch2ID)
            while controller.isAnyBookActive {
                try await Task.sleep(for: .milliseconds(500))
            }
        } else {
            print(">>> CHAPTER 2 ALREADY HAS 100% TEXT SEGMENTS (\(initialCh2Segs.count)/\(initialCh2Segs.count))")
        }

        // 2. Synthesize Chapter 7 (idx 6: "Scrooge’s Third Visitor")
        guard let bookAfterCh2 = libraryStore.book(id: bookID) else {
            XCTFail("Failed to load book after chapter 2")
            return
        }
        let ch7ID = bookAfterCh2.chapters[6].id
        print(">>> STARTING SYNTHESIS OF CHAPTER 7 (\(bookAfterCh2.chapters[6].title))...")
        controller.regenerateChapter(bookID: bookID, chapterID: ch7ID)
        while controller.isAnyBookActive {
            try await Task.sleep(for: .milliseconds(500))
        }

        // Explicitly flush memory state to disk
        libraryStore.flush()

        // 3. Reload fresh from disk and verify segments
        let freshStore = LibraryStore()
        guard let finalBook = freshStore.book(id: bookID) else {
            XCTFail("Failed to reload book from disk after chapter 7")
            return
        }

        let ch2Segs = finalBook.chapters[1].audioSegments ?? []
        let ch7Segs = finalBook.chapters[6].audioSegments ?? []

        let ch2Dur = finalBook.chapters[1].audioDurationSeconds ?? 0
        let ch7Dur = finalBook.chapters[6].audioDurationSeconds ?? 0

        print(">>> CHAPTER 2 RESULT (FROM DISK): \(ch2Segs.count) segments, duration \(ch2Dur)s")
        print(">>> CHAPTER 7 RESULT (FROM DISK): \(ch7Segs.count) segments, duration \(ch7Dur)s")

        XCTAssertFalse(ch2Segs.isEmpty, "Chapter 2 must have audio segments")
        let ch2TextSegments = ch2Segs.filter { $0.text != nil && !$0.text!.isEmpty }
        XCTAssertEqual(ch2TextSegments.count, ch2Segs.count, "100% of Chapter 2 segments must contain text")

        XCTAssertFalse(ch7Segs.isEmpty, "Chapter 7 must have audio segments")
        let ch7TextSegments = ch7Segs.filter { $0.text != nil && !$0.text!.isEmpty }
        XCTAssertEqual(ch7TextSegments.count, ch7Segs.count, "100% of Chapter 7 segments must contain text")
    }
}
