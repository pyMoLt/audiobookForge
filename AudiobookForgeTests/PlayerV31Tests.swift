import XCTest
@testable import AudiobookForge

/// v3.1 player/reader logic: paragraph grouping, listening progress,
/// settings pane search.
final class PlayerV31Tests: XCTestCase {
    private func segment(_ index: Int, _ text: String, start: Double) -> TTSSegment {
        TTSSegment(index: index, startSeconds: start, durationSeconds: 2, text: text)
    }

    func testParagraphsFollowLineBreaksInText() {
        let text = "Erster Satz hier. Zweiter Satz folgt.\n\nNeuer Absatz beginnt. Und endet hier.\nDritter Absatz."
        let segments = [
            segment(0, "Erster Satz hier.", start: 0),
            segment(1, "Zweiter Satz folgt.", start: 2),
            segment(2, "Neuer Absatz beginnt.", start: 4),
            segment(3, "Und endet hier.", start: 6),
            segment(4, "Dritter Absatz.", start: 8),
        ]
        let paragraphs = ReadAlongLayout.paragraphs(fullText: text, segments: segments)
        XCTAssertEqual(paragraphs.map { $0.segments.map(\.index) }, [[0, 1], [2, 3], [4]])
    }

    func testFlatTextIsCutIntoReadableParagraphs() {
        let sentences = (0..<14).map { "Satz Nummer \($0) ist da." }
        let text = sentences.joined(separator: " ")
        let segments = sentences.enumerated().map { segment($0.offset, $0.element, start: Double($0.offset) * 2) }
        let paragraphs = ReadAlongLayout.paragraphs(fullText: text, segments: segments, fallbackLength: 6)
        XCTAssertEqual(paragraphs.map(\.segments.count), [6, 6, 2])
    }

    func testSegmentsWithoutTextAreSkipped() {
        let segments = [segment(0, "Hallo Welt.", start: 0), TTSSegment(index: 1, startSeconds: 2, durationSeconds: 1, text: nil)]
        let paragraphs = ReadAlongLayout.paragraphs(fullText: "Hallo Welt.", segments: segments)
        XCTAssertEqual(paragraphs.flatMap { $0.segments.map(\.index) }, [0])
    }

    func testSentencesAreAlignedToTextlessTimingChunks() {
        // Kokoro: 2 timing chunks without text, 4 sentences of equal length.
        let text = "Aaaa aaaa. Bbbb bbbb. Cccc cccc. Dddd dddd."
        let timing = [
            TTSSegment(index: 0, startSeconds: 0, durationSeconds: 4, text: nil),
            TTSSegment(index: 1, startSeconds: 5, durationSeconds: 4, text: nil),
        ]
        let aligned = ReadAlongLayout.alignedSegments(fullText: text, timing: timing)
        XCTAssertEqual(aligned.count, SentenceSplitter.split(text).count)
        XCTAssertTrue(aligned.allSatisfy { $0.text != nil })
        // Starts increase monotonically and the pause between chunks is skipped.
        XCTAssertEqual(aligned.map(\.startSeconds), aligned.map(\.startSeconds).sorted())
        XCTAssertEqual(aligned.first?.startSeconds ?? -1, 0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(aligned.last?.startSeconds ?? 0, 5)
        XCTAssertEqual(ReadAlongLayout.segmentIndex(at: 0.5, in: aligned), 0)
        XCTAssertEqual(ReadAlongLayout.segmentIndex(at: 8.5, in: aligned), aligned.last?.index)
    }

    func testAlignmentKeepsEngineTextWhenPresent() {
        let timing = [TTSSegment(index: 0, startSeconds: 0, durationSeconds: 2, text: "Hallo.")]
        XCTAssertEqual(ReadAlongLayout.alignedSegments(fullText: "Hallo.", timing: timing), timing)
    }

    func testChunkTextIsSplitIntoSentencesWithinItsOwnTime() {
        // Kokoro chunk = paragraph with two sentences, followed by a pause.
        let timing = [
            TTSSegment(index: 0, startSeconds: 0, durationSeconds: 4, text: "Satz eins hier. Satz zwei hier."),
            TTSSegment(index: 1, startSeconds: 5, durationSeconds: 2, text: "Dritter."),
        ]
        let aligned = ReadAlongLayout.alignedSegments(fullText: "x", timing: timing)
        XCTAssertEqual(aligned.count, 3)
        XCTAssertEqual(aligned[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(aligned[1].startSeconds, 2, accuracy: 0.001, "gleich lange Sätze teilen die Chunk-Dauer")
        XCTAssertEqual(aligned[2].startSeconds, 5, accuracy: 0.001, "Chunk-Grenzen bleiben exakt")
    }

    func testListenedSecondsForBothModes() {
        let durations = [100.0, 200.0, 300.0]
        let absolute = PlaybackProgressStore.Saved(chapterIndex: 2, time: 350, isAbsolute: true)
        XCTAssertEqual(PlaybackProgressStore.listenedSeconds(absolute, chapterDurations: durations), 350)
        let relative = PlaybackProgressStore.Saved(chapterIndex: 2, time: 50, isAbsolute: false)
        XCTAssertEqual(PlaybackProgressStore.listenedSeconds(relative, chapterDurations: durations), 350)
    }

    func testSavedPositionStaysBackwardCompatible() throws {
        // v3.0 entries had no lastPlayedAt — they must still decode.
        let old = #"{"chapterIndex":3,"time":12.5,"isAbsolute":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PlaybackProgressStore.Saved.self, from: old)
        XCTAssertEqual(decoded.chapterIndex, 3)
        XCTAssertNil(decoded.lastPlayedAt)
    }

    func testListeningTimeFormatting() {
        XCTAssertEqual(ListeningTimeFormatter.clock(65), "1:05")
        XCTAssertEqual(ListeningTimeFormatter.clock(3725), "1:02:05")
        let formattedLong = ListeningTimeFormatter.long(3600 * 4 + 12 * 60)
        XCTAssertTrue(formattedLong == "4 Std. 12 Min." || formattedLong == "4 h 12 min", "Expected '4 Std. 12 Min.' (de) or '4 h 12 min' (en), got \(formattedLong)")
        let formattedZero = ListeningTimeFormatter.long(0)
        XCTAssertTrue(formattedZero == "0 Min." || formattedZero == "0 min", "Expected '0 Min.' (de) or '0 min' (en), got \(formattedZero)")
    }

    func testListeningTimeCompactFormatting() {
        XCTAssertTrue(ListeningTimeFormatter.compact(0) == "0 Min." || ListeningTimeFormatter.compact(0) == "0 min")
        XCTAssertTrue(ListeningTimeFormatter.compact(720) == "12 Min." || ListeningTimeFormatter.compact(720) == "12 min")
        XCTAssertEqual(ListeningTimeFormatter.compact(3600), "1 h")
        XCTAssertEqual(ListeningTimeFormatter.compact(3600 * 12), "12 h")
        let compactHalf = ListeningTimeFormatter.compact(3600 * 1.5)
        XCTAssertTrue(compactHalf == "1,5 h" || compactHalf == "1.5 h")
    }

    func testNumberAbbreviationFormatting() {
        XCTAssertEqual(ListeningTimeFormatter.abbreviateCount(0), "0")
        XCTAssertEqual(ListeningTimeFormatter.abbreviateCount(999), "999")
        XCTAssertEqual(ListeningTimeFormatter.abbreviateCount(1000), "1k")
        let formatted1200 = ListeningTimeFormatter.abbreviateCount(1200)
        XCTAssertTrue(formatted1200 == "1,2k" || formatted1200 == "1.2k")
        XCTAssertEqual(ListeningTimeFormatter.abbreviateCount(10000), "10k")
        XCTAssertEqual(ListeningTimeFormatter.abbreviateCount(1_000_000), "1M")
    }

    func testSettingsSearchFindsTimeoutInAIPane() {
        XCTAssertTrue(SettingsPane.ai.matches("Timeout"))
        XCTAssertTrue(SettingsPane.output.matches("lufs"))
        XCTAssertFalse(SettingsPane.appearance.matches("zauberstein"))
    }

    func testSurfaceLevelRoundTripsLegacyIntensity() {
        XCTAssertEqual(SurfaceLevel(intensity: 80), .frosted, "v3.0-Standard 80 bleibt milchig")
        for level in SurfaceLevel.allCases {
            XCTAssertEqual(SurfaceLevel(intensity: level.intensity), level)
        }
    }
}
