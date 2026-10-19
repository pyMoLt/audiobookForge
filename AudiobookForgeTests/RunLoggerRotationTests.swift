import XCTest
@testable import AudiobookForge

final class RunLoggerRotationTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeLog(_ name: String, in dir: URL, bytes: Int, age: TimeInterval) throws {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    func testRemovesOldestBeyondFileLimit() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5 { try makeLog("\(i).log", in: dir, bytes: 10, age: Double(100 - i)) }
        RunLogger.rotate(directory: dir, maxFiles: 3, maxBytes: 1_000)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["2.log", "3.log", "4.log"])
    }

    func testRemovesOldestBeyondSizeLimitAndIgnoresOtherFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeLog("old.log", in: dir, bytes: 600, age: 50)
        try makeLog("new.log", in: dir, bytes: 600, age: 10)
        try makeLog("keep.txt", in: dir, bytes: 5_000, age: 500)
        RunLogger.rotate(directory: dir, maxFiles: 20, maxBytes: 1_000)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["keep.txt", "new.log"])
    }

    func testInitKeepsAtMostLimitIncludingNewLog() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<25 { try makeLog("\(i).log", in: dir, bytes: 10, age: Double(1_000 - i)) }
        let logger = RunLogger(bookID: UUID(), bookTitle: "T", directory: dir)
        logger.close()
        let count = try FileManager.default.contentsOfDirectory(atPath: dir.path).count
        XCTAssertEqual(count, RunLogger.maxLogFiles)
    }
}
