import Foundation
import XCTest
@testable import AudiobookForge

final class NewTTSEngineIntegrationTests: XCTestCase {
    func testGermanMLXEnginesAndSupertonicProduceAudio() async throws {
        let cases: [(TTSEngineID, String)] = [
            (.kokoroGerman, "martin"),
            (.kokoroGerman, "victoria"),
            (.kokoroThorsten, "thorsten"),
            (.supertonic3, "M1"),
        ]
        let text = "Guten Tag. Die Brücke führt über den Fluss."
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookForge-new-tts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = AppSettings()
        settings.supertonicSteps = 5
        for (engineID, voice) in cases {
            let engine = TTSEngineFactory.engine(for: engineID, settings: settings)
            let ready = await engine.isReady(voice: voice)
            XCTAssertTrue(ready, "\(engineID) / \(voice) is not ready")
            let output = directory.appendingPathComponent("\(engineID.rawValue)-\(voice).m4a")
            let result = try await engine.synthesize(text: text, voice: voice, speed: 1.0, outputURL: output, onProgress: { _ in })
            XCTAssertGreaterThan(result.durationSeconds, 1, "\(engineID) / \(voice)")
            XCTAssertGreaterThan(try Data(contentsOf: output).count, 1000)
            XCTAssertEqual(output.pathExtension, "m4a")
            XCTAssertLessThan(try Data(contentsOf: output).count, 200_000, "Chapter file should stay small (compressed, not PCM)")
        }
    }
}
