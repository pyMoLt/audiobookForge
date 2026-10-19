import XCTest
@testable import AudiobookForge

/// Phase 1 (4.4): library persistence is debounced (≤ 1 write per 2 s
/// under sustained updates), never starves, and loses nothing on quit.
final class PersistenceDebounceTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        LibraryStore.writeCount.withLock { $0 = 0 }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func makeBook(titled title: String) -> BookProject {
        BookProject(title: title, author: "Test", sourceType: .pdf, sourceURL: URL(fileURLWithPath: "/dev/null"), chapters: [], outputFormat: .m4b, voice: "af_heart", speechSpeed: 1.0)
    }

    private func readBooks() throws -> [BookProject] {
        let data = try Data(contentsOf: work.appendingPathComponent("library.json"))
        return try JSONDecoder().decode([BookProject].self, from: data)
    }

    /// 100 upserts within ~1 s must produce at most 2 writes (one
    /// debounced/coalesced write, at most one max-age flush).
    func testSustainedUpsertsProduceAtMostTwoWrites() async throws {
        let store = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        var book = makeBook(titled: "Debounce")
        for i in 1...100 {
            book.chapters = [] // touch the book so each upsert is a real change
            book.lastErrorMessage = "Tick \(i)"
            store.upsert(book)
            try await Task.sleep(for: .milliseconds(10))
        }
        store.flush()
        let writes = LibraryStore.writeCount.withLock { $0 }
        XCTAssertLessThanOrEqual(writes, 2, "expected ≤ 2 writes for 100 upserts in 1 s, got \(writes)")
        XCTAssertEqual(try readBooks().count, 1)
    }

    /// The max-age guarantee: even without a quiet moment, a dirty state
    /// older than 2 s is written (no starvation under continuous updates).
    func testMaxAgeFlushPreventsStarvation() async throws {
        let store = LibraryStore(fileURL: work.appendingPathComponent("library.json"), debounceInterval: 0.3, maxDirtyAge: 1.0)
        var book = makeBook(titled: "Starvation")
        book.lastErrorMessage = "Start"
        store.upsert(book)
        for i in 1...12 {
            try await Task.sleep(for: .milliseconds(100))
            book.lastErrorMessage = "Tick \(i)"
            store.upsert(book)
        }
        // 1.2 s of continuous updates with a 1 s max age: at least one
        // write must have happened without flush().
        let writes = LibraryStore.writeCount.withLock { $0 }
        XCTAssertGreaterThanOrEqual(writes, 1, "dirty state starved — max-age flush did not fire")
        XCTAssertTrue(try readBooks().first?.lastErrorMessage?.hasPrefix("Tick") == true, "latest flushed snapshot must be on disk")
    }

    /// Nothing is lost when the app terminates: flush writes the current
    /// state synchronously.
    func testFlushWritesCurrentState() throws {
        let store = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        store.upsert(makeBook(titled: "Eins"))
        store.upsert(makeBook(titled: "Zwei"))
        store.flush()
        XCTAssertEqual(try readBooks().map(\.title).sorted(), ["Eins", "Zwei"])

        // A fresh store reads the same state back.
        let reloaded = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        XCTAssertEqual(reloaded.books.count, 2)
    }

    func testRemoveDeletesBookDirectoryAndChapterAudio() throws {
        let store = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        let book = makeBook(titled: "ToDelete")
        store.upsert(book)
        store.flush()
        XCTAssertEqual(store.books.count, 1)

        let chapterDir = try ChapterAudioStore.prepareChapterAudioDirectory(bookID: book.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chapterDir.path))

        store.remove(book)
        store.flush()

        XCTAssertEqual(store.books.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chapterDir.path))
    }
}
