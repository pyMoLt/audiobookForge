import XCTest
@testable import AudiobookForge

/// v4.4 audio chain: calm/dynamic normalization, clean-up, the M4B bitrate
/// fix, the quality check's parsing and verdicts, the new defaults.
final class AudioPolishTests: XCTestCase {
    func testDefaultsAreCalmWithCleanUpAndBestQuality() {
        let settings = AppSettings()
        XCTAssertEqual(settings.loudnessMode, .calm)
        XCTAssertTrue(settings.audioEnhancementEnabled)
        XCTAssertEqual(settings.mp3Quality, 0)
        XCTAssertEqual(settings.aacBitrateKbps, 128)
        XCTAssertEqual(settings.phononRefinementSteps, 1)
    }

    func testCalmArgumentsWriteLosslessStageWithCleanUp() throws {
        let settings = AppSettings()
        let output = URL(fileURLWithPath: "/tmp/book/003.m4a")
        let arguments = try ChapterAudioEncoder.arguments(sampleRate: 24000, outputURL: output, settings: settings)
        XCTAssertEqual(arguments.last, "/tmp/book/003.stage.flac")
        XCTAssertTrue(arguments.contains(AudioPolish.enhancementFilter))
        XCTAssertFalse(arguments.contains { $0.contains("loudnorm") }, "Calm mode must not ride the gain")
    }

    func testChapterAACUsesTheBookBitrate() throws {
        var settings = AppSettings()
        settings.aacBitrateKbps = 96
        let codec = try AudioPolish.codecArguments(for: URL(fileURLWithPath: "/tmp/000.m4a"), settings: settings)
        XCTAssertEqual(codec.prefix(4), ["-c:a", "aac", "-b:a", "96k"])
    }

    func testNoNormalizationNoCleanUpIsAPlainEncode() throws {
        var settings = AppSettings()
        settings.loudnessNormalizationEnabled = false
        settings.audioEnhancementEnabled = false
        let arguments = try ChapterAudioEncoder.arguments(sampleRate: 22050, outputURL: URL(fileURLWithPath: "/tmp/000.mp3"), settings: settings)
        XCTAssertFalse(arguments.contains("-af"))
        XCTAssertEqual(arguments.last, "/tmp/000.mp3")
        XCTAssertTrue(arguments.contains("libmp3lame"))
    }

    func testCalmGainAndLimiter() {
        XCTAssertEqual(AudioPolish.calmGain(measuredLUFS: -21.4, targetLUFS: -18), 3.4, accuracy: 0.001)
        XCTAssertEqual(AudioPolish.calmGain(measuredLUFS: nil, targetLUFS: -18), 0)
        XCTAssertEqual(AudioPolish.calmGain(measuredLUFS: -90, targetLUFS: -18), 0, "Silence gets no gain")
        XCTAssertEqual(AudioPolish.calmGain(measuredLUFS: -60, targetLUFS: -18), 30, "Gain is capped")
        XCTAssertEqual(AudioPolish.calmFilter(gainDB: 3.4, truePeakDB: -1.5),
                       "volume=3.40dB,alimiter=limit=0.8414:attack=5:release=50:level=disabled")
    }

    func testParsesFFmpegSummaries() {
        let lines = [
            "[Parsed_silencedetect_1 @ 0x1] silence_end: 9.5 | silence_duration: 5.25",
            "    I:         -17.8 LUFS",
            "    Peak:       -1.5 dBFS",
            "[Parsed_astats_2 @ 0x2] Max difference: 0.731860",
            "[Parsed_astats_2 @ 0x2] Peak level dB: -0.000000",
            "[Parsed_astats_2 @ 0x2] Peak count: 12.000000",
        ]
        let report = ChapterQualityReport.parse(lines)
        XCTAssertEqual(report.integratedLUFS, -17.8)
        XCTAssertEqual(report.truePeakDB, -1.5)
        XCTAssertEqual(report.peakCount, 12)
        XCTAssertEqual(report.silences, [5.25])
        let findings = report.findings(targetLUFS: -18)
        XCTAssertEqual(findings.count, 3, "\(findings)")
        XCTAssertTrue(findings[0].contains("12"))
    }

    func testCleanChapterIsFine() {
        let report = ChapterQualityReport(integratedLUFS: -18.2, truePeakDB: -1.6, samplePeakDB: -1.7, peakCount: 1,
                                          maxDifference: 0.23, silences: [0.55, 1.0])
        XCTAssertTrue(report.findings(targetLUFS: -18).isEmpty)
        XCTAssertFalse(report.findings(targetLUFS: -23).isEmpty, "5 LU off target is noted")
    }

    func testOldDefaultMP3QualityMovesOnce() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"mp3Quality": 2}"#.utf8))
        XCTAssertEqual(old.mp3Quality, 0)
        let deliberate = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"mp3Quality": 2, "audioDefaultsRevision": 1}"#.utf8))
        XCTAssertEqual(deliberate.mp3Quality, 2, "After the move, 2 is a deliberate choice")
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(deliberate))
        XCTAssertEqual(roundTrip.mp3Quality, 2)
    }

    func testPhononStepsKeepTheNeuralEngineOnlyAtOne() {
        XCTAssertTrue(PhononEngine.usesNeuralEngine(profile: .saver, speed: 1, refinementSteps: 1, neuralReady: true))
        XCTAssertFalse(PhononEngine.usesNeuralEngine(profile: .saver, speed: 1, refinementSteps: 2, neuralReady: true))
    }
}
