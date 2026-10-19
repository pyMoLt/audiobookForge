import CryptoKit
import Foundation
import XCTest
@testable import AudiobookForge

final class RuntimeInstallerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ABFRuntimeTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testRuntimeTypeCalculation() {
        let fakeRuntime = tempDir.appendingPathComponent("runtime", isDirectory: true)
        let installer = RuntimeInstaller(runtimeDirectory: fakeRuntime)

        // Without python or ffmpeg
        XCTAssertFalse(installer.isStandalonePythonReady)
        XCTAssertFalse(installer.isStandaloneFFmpegReady)
        XCTAssertFalse(installer.isRuntimeReady)

        // Create fake executables
        let pyBin = fakeRuntime.appendingPathComponent("python/bin", isDirectory: true)
        let ffmpegBin = fakeRuntime.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: pyBin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: ffmpegBin, withIntermediateDirectories: true)

        let pyFile = pyBin.appendingPathComponent("python3")
        let ffmpegFile = ffmpegBin.appendingPathComponent("ffmpeg")

        FileManager.default.createFile(atPath: pyFile.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        FileManager.default.createFile(atPath: ffmpegFile.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pyFile.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegFile.path)

        XCTAssertTrue(installer.isStandalonePythonReady)
        XCTAssertTrue(installer.isStandaloneFFmpegReady)
        XCTAssertTrue(installer.isRuntimeReady)
        XCTAssertEqual(installer.runtimeType, .standalone)
    }

    func testDownloadWithSHA256ChecksumVerification() async throws {
        let fakeRuntime = tempDir.appendingPathComponent("runtime", isDirectory: true)
        let installer = RuntimeInstaller(runtimeDirectory: fakeRuntime)

        let testContent = "AudiobookForge Test Payload for Checksum Verification"
        let testData = Data(testContent.utf8)
        let expectedHash = SHA256.hash(data: testData).map { String(format: "%02x", $0) }.joined()

        let localSourceURL = tempDir.appendingPathComponent("source_payload.bin")
        try testData.write(to: localSourceURL)

        installer.ffmpegDownloadURL = localSourceURL
        installer.ffmpegExpectedSHA256 = expectedHash

        // Test successful download and extraction
        try await installer.installFFmpeg { progress in
            XCTAssertGreaterThanOrEqual(progress.fractionCompleted, 0.0)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.ffmpegURL.path))

        // Test mismatched checksum
        let badInstaller = RuntimeInstaller(runtimeDirectory: fakeRuntime)
        badInstaller.ffmpegDownloadURL = localSourceURL
        badInstaller.ffmpegExpectedSHA256 = "0000000000000000000000000000000000000000000000000000000000000000"

        do {
            try await badInstaller.installFFmpeg { _ in }
            XCTFail("Should have thrown checksumMismatch error")
        } catch let RuntimeInstallerError.checksumMismatch(expected, actual) {
            XCTAssertEqual(expected, "0000000000000000000000000000000000000000000000000000000000000000")
            XCTAssertEqual(actual, expectedHash)
        }
    }

    func testModelManagerCatalogIntegrity() {
        let manager = ModelManager.shared
        let models = manager.availableModels

        XCTAssertFalse(models.isEmpty, "Model catalog must not be empty")

        for item in models {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.license.isEmpty)
            XCTAssertGreaterThan(item.estimatedSizeBytes, 0)
            XCTAssertFalse(item.sizeFormatted.isEmpty)
        }

        // Verify key model presence
        let ids = Set(models.map(\.id))
        XCTAssertTrue(ids.contains("kokoro-de-martin"))
        XCTAssertTrue(ids.contains("kokoro-de-victoria"))
        XCTAssertTrue(ids.contains("piper-de-thorsten-medium"))
        XCTAssertTrue(ids.contains("supertonic-3"))
        XCTAssertTrue(ids.contains("omnivoice-base"))
        // Qwen3-TTS was removed (v3.2, user decision): no model entry left.
        XCTAssertFalse(ids.contains("qwen3-base-8bit"))
    }
}
