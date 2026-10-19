import XCTest
@testable import AudiobookForge

final class StorageReportServiceTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFetchReportComputesSizesAccurately() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let sampleData = Data(repeating: 0x41, count: 2048)
        try sampleData.write(to: logsDir.appendingPathComponent("test.log"))

        let service = StorageReportService()
        let report = await service.fetchReport(baseDirectory: tempDir)

        guard let logItem = report.first(where: { $0.id == "logs" }) else {
            XCTFail("logs item not found")
            return
        }
        XCTAssertEqual(logItem.byteCount, 2048)
    }

    func testCleanAllNonEssentialDeletesFiles() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1000).write(to: logsDir.appendingPathComponent("a.log"))

        let audioDir = tempDir.appendingPathComponent("chapter_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 5000).write(to: audioDir.appendingPathComponent("temp.m4a"))

        let service = StorageReportService()
        try service.cleanAllNonEssential(baseDirectory: tempDir)

        let logFiles = try FileManager.default.contentsOfDirectory(atPath: logsDir.path)
        let audioFiles = try FileManager.default.contentsOfDirectory(atPath: audioDir.path)
        XCTAssertTrue(logFiles.isEmpty)
        XCTAssertTrue(audioFiles.isEmpty)
    }
}
