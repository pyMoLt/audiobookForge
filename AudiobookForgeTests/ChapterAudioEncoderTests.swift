import XCTest
@testable import AudiobookForge

/// Verifies the streaming encoder core of the storage rework: raw PCM goes
/// in, a small compressed chapter file comes out — loudness normalization
/// included in the same pass, no WAV intermediate anywhere. Uses synthetic
/// sine PCM so these tests need no TTS environment.
final class ChapterAudioEncoderTests: XCTestCase {
    private var settings: AppSettings!

    override func setUp() {
        settings = AppSettings()
        settings.loudnessNormalizationEnabled = true
    }

    /// One second of mono 16-bit sine PCM.
    private func sinePCM(seconds: Double, sampleRate: Int, amplitude: Double = 0.5) -> Data {
        var data = Data()
        let sampleCount = Int(Double(sampleRate) * seconds)
        data.reserveCapacity(sampleCount * 2)
        for sample in 0..<sampleCount {
            let value = sin(2.0 * .pi * 440.0 * Double(sample) / Double(sampleRate)) * amplitude
            var int16 = Int16(clamping: Int(value * 32000))
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testEncodesPCMToCompressedM4AInOnePass() async throws {
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pcm = sinePCM(seconds: 3.0, sampleRate: 22050)
        let outputURL = directory.appendingPathComponent("000.m4a")
        let encoder = try ChapterAudioEncoder.start(sampleRate: 22050, outputURL: outputURL, settings: settings, stdinPipe: Pipe())

        // Feed in small chunks like a real streaming producer would.
        var offset = 0
        let chunkSize = 4096
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            try encoder.write(pcm.subdata(in: offset..<end))
            offset = end
        }
        let duration = try await encoder.finish()

        XCTAssertEqual(duration, 3.0, accuracy: 0.15, "Encoded duration should match the PCM stream")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // Compressed, not raw: 3 s of PCM are 132 KB; AAC at 64 kbps is ~24 KB.
        let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, pcm.count / 2, "Chapter file must be far smaller than the raw PCM")

        let wavFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
        XCTAssertTrue(wavFiles.isEmpty, "No WAV intermediate may be created")
    }

    func testEncodesPCMToMP3() async throws {
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pcm = sinePCM(seconds: 2.0, sampleRate: 22050)
        let outputURL = directory.appendingPathComponent("000.mp3")
        let encoder = try ChapterAudioEncoder.start(sampleRate: 22050, outputURL: outputURL, settings: settings, stdinPipe: Pipe())
        try encoder.write(pcm)
        let duration = try await encoder.finish()

        XCTAssertEqual(duration, 2.0, accuracy: 0.15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, pcm.count / 2)
    }

    func testLoudnessDisabledStillEncodes() async throws {
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        settings.loudnessNormalizationEnabled = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("000.m4a")
        let encoder = try ChapterAudioEncoder.start(sampleRate: 24000, outputURL: outputURL, settings: settings, stdinPipe: Pipe())
        try encoder.write(sinePCM(seconds: 1.0, sampleRate: 24000))
        let duration = try await encoder.finish()

        XCTAssertEqual(duration, 1.0, accuracy: 0.15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testAbortRemovesPartialOutput() throws {
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("000.m4a")
        let encoder = try ChapterAudioEncoder.start(sampleRate: 22050, outputURL: outputURL, settings: settings, stdinPipe: Pipe())
        try encoder.write(sinePCM(seconds: 1.0, sampleRate: 22050))
        encoder.abort()

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), "Abort must not leave a partial chapter file behind")
    }

    func testFinishWithoutPCMThrows() async throws {
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("000.m4a")
        let encoder = try ChapterAudioEncoder.start(sampleRate: 22050, outputURL: outputURL, settings: settings, stdinPipe: Pipe())
        do {
            _ = try await encoder.finish()
            XCTFail("finish() without any PCM must throw")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }
}
