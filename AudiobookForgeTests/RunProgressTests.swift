import XCTest
@testable import AudiobookForge

/// Phase 1 (4.1): progress model — stage resets, monotonic overall
/// fraction, and independent per-worker chapter fractions.
@MainActor
final class RunProgressTests: XCTestCase {

    private func makeProgress() -> RunProgress {
        var progress = RunProgress()
        progress.phases = RunProgress.phases(hasImagePass: true, hasSummary: true)
        progress.chapterCharacterCounts = [1000, 1000, 1000, 1000, 1000]
        progress.chapterCount = 5
        progress.charactersPerAudioSecond = 10
        return progress
    }

    /// `enterStage` must clear every per-phase field so nothing of the
    /// previous phase (chapter rows, segment counts, phase bar) leaks
    /// into the next one.
    func testEnterStageResetsChapterFieldsAndSegments() {
        var progress = makeProgress()
        progress.stage = .describingImages
        progress.phaseFraction = 1
        progress.detail = "Abbildung 5/5"
        progress.imagesDone = 5
        progress.imagesTotal = 5
        progress.activeChapters[2] = RunProgress.ChapterProgress(
            index: 2, title: "Altes Kapitel", fraction: 0.7, segmentsDone: 3, plannedSegments: 4, audioSeconds: 12
        )
        progress.chaptersCompleted = 2
        progress.llmCharactersDone = 500
        progress.llmCharactersTotal = 1000
        progress.llmRateSamples = [RunProgress.RateSample(time: Date(), value: 500)]
        progress.synthesisRateSamples = [RunProgress.RateSample(time: Date(), value: 10)]

        progress.enterStage(.summarizing, detail: "Neu")

        XCTAssertEqual(progress.stage, .summarizing)
        XCTAssertEqual(progress.phaseFraction, 0)
        XCTAssertEqual(progress.activeChapters, [:])
        XCTAssertEqual(progress.chaptersCompleted, 0)
        XCTAssertEqual(progress.imagesDone, 0)
        XCTAssertEqual(progress.imagesTotal, 0)
        XCTAssertEqual(progress.llmCharactersDone, 0)
        XCTAssertEqual(progress.llmCharactersTotal, 0)
        XCTAssertTrue(progress.llmRateSamples.isEmpty)
        XCTAssertTrue(progress.synthesisRateSamples.isEmpty)
        XCTAssertEqual(progress.detail, "Neu")
    }

    /// The overall bar may never move backwards while a run progresses
    /// through its stages — a stage switch must land exactly at the
    /// previous value, not below it.
    func testOverallFractionIsMonotonicAcrossStages() {
        var progress = makeProgress()
        var last = progress.overallFraction
        var observed: [Double] = [last]

        func step(_ fraction: Double, thenAssert: Bool = true) {
            progress.phaseFraction = fraction
            let value = progress.overallFraction
            if thenAssert {
                XCTAssertGreaterThanOrEqual(value + 1e-9, last, "overall fraction decreased at stage \(progress.stage)")
            }
            last = value
            observed.append(value)
        }

        progress.enterStage(.extracting)
        step(0.5); step(1)
        progress.enterStage(.describingImages)
        step(0); step(0.5); step(1)
        progress.enterStage(.summarizing)
        step(0); step(0.25); step(1)
        progress.enterStage(.synthesizing)
        step(0); step(0.4); step(1)
        progress.enterStage(.packaging)
        step(0); step(1)
        progress.enterStage(.done)
        XCTAssertEqual(progress.overallFraction, 1)
        // Sanity: the run actually covered the full range.
        XCTAssertGreaterThan(observed.max() ?? 0, 0.9)
    }

    /// Two parallel workers each track their own chapter fraction —
    /// progress of one never clobbers the other.
    func testTwoWorkersReportIndependentFractions() {
        var progress = makeProgress()
        progress.enterStage(.synthesizing)
        progress.activeChapters[1] = RunProgress.ChapterProgress(index: 1, title: "Kapitel 2", fraction: 0, plannedSegments: 10)
        progress.activeChapters[2] = RunProgress.ChapterProgress(index: 2, title: "Kapitel 3", fraction: 0, plannedSegments: 4)

        // Worker on chapter 2 finishes 5 of 10 segments.
        progress.activeChapters[1]?.segmentsDone = 5
        progress.activeChapters[1]?.fraction = 0.5
        progress.activeChapters[1]?.audioSeconds = 30

        XCTAssertEqual(progress.activeChapters[1]?.fraction, 0.5)
        XCTAssertEqual(progress.activeChapters[2]?.fraction, 0)
        XCTAssertEqual(progress.activeChapters[2]?.segmentsDone, 0)
        XCTAssertEqual(progress.activeChapters[1]?.audioSeconds, 30)
        XCTAssertEqual(progress.activeChapters[2]?.audioSeconds, 0)

        XCTAssertEqual(progress.primaryChapterIndex, 1)
        XCTAssertEqual(progress.sortedActiveChapters.map(\.index), [1, 2])
        XCTAssertEqual(progress.activeAudioSeconds, 30)

        // Worker on chapter 3 advances independently and faster.
        progress.activeChapters[2]?.segmentsDone = 4
        progress.activeChapters[2]?.fraction = 1
        progress.activeChapters[2]?.audioSeconds = 40
        XCTAssertEqual(progress.activeChapters[1]?.fraction, 0.5)
        XCTAssertEqual(progress.producedAudioSeconds, 70)
    }

    /// Regression for "progress bar at the bottom stays at 100 %":
    /// after the image pass completes (phaseFraction 1) and again after
    /// summarization, the phase bar must restart at 0.
    func testPhaseBarResetsAfterImagePassAndSummary() {
        var progress = makeProgress()

        progress.enterStage(.describingImages)
        progress.phaseFraction = 1
        XCTAssertEqual(progress.phaseFraction, 1)
        progress.enterStage(.summarizing)
        XCTAssertEqual(progress.phaseFraction, 0, "phase bar must reset when entering the summary stage")

        progress.phaseFraction = 1
        progress.enterStage(.synthesizing)
        XCTAssertEqual(progress.phaseFraction, 0, "phase bar must reset when entering synthesis")

        progress.phaseFraction = 0.42
        progress.enterStage(.packaging)
        XCTAssertEqual(progress.phaseFraction, 0, "phase bar must reset when entering packaging")
    }

    /// Synthesis text share counts every active worker's chapter
    /// proportionally — two workers at 50 % of different chapters count
    /// both.
    func testSynthesisTextFractionCountsAllActiveWorkers() {
        var progress = makeProgress()
        progress.enterStage(.synthesizing)
        progress.activeChapters[0] = RunProgress.ChapterProgress(index: 0, title: "Eins", fraction: 0.5)
        progress.activeChapters[1] = RunProgress.ChapterProgress(index: 1, title: "Zwei", fraction: 1)
        // 500 chars of chapter 1 (half) + 1000 chars of chapter 2 (done) = 1500 of 5000.
        XCTAssertEqual(progress.synthesisTextFraction, 0.3, accuracy: 0.001)
    }

    /// Sliding-window rates need a 10 s span; short bursts stay nil so
    /// the ETA falls back to phase-wide or default rates.
    func testWindowedRateNeedsSpanAndIsComputedFromSamples() {
        var progress = makeProgress()
        progress.enterStage(.synthesizing)
        let now = Date()

        progress.synthesisRateSamples = [
            RunProgress.RateSample(time: now.addingTimeInterval(-5), value: 10),
            RunProgress.RateSample(time: now, value: 20),
        ]
        XCTAssertNil(progress.windowedRealTimeFactor, "window shorter than 10 s must not produce a rate")

        progress.synthesisRateSamples = [
            RunProgress.RateSample(time: now.addingTimeInterval(-60), value: 10),
            RunProgress.RateSample(time: now, value: 70),
        ]
        // 60 s of audio in 60 s of wall time → RTF 1.0 (0.5 audio s/s wall).
        XCTAssertEqual(progress.windowedRealTimeFactor ?? -1, 1.0, accuracy: 0.05)

        progress.llmRateSamples = [
            RunProgress.RateSample(time: now.addingTimeInterval(-30), value: 0),
            RunProgress.RateSample(time: now, value: 3000),
        ]
        XCTAssertEqual(progress.windowedLLMCharactersPerSecond ?? -1, 100, accuracy: 1)
    }
}
