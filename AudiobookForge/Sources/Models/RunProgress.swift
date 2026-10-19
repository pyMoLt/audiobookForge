import Foundation

/// Live, non-persisted progress of one running pipeline. Owned by
/// `PipelineController`, rendered by `ProcessingView` and the sidebar.
///
/// Overall progress is a weighted sum over the phases this run actually
/// has (image pass and summarization only when applicable); synthesis
/// dominates the wall time, so it gets most of the weight. Within
/// synthesis, progress is measured in *audio seconds produced* against an
/// estimate derived from text length, recalibrated after every finished
/// chapter — engines report segment durations, not text positions, so
/// audio time is the one unit every engine can deliver.
///
/// With parallel synthesis workers there is no single "current chapter":
/// every worker tracks its own `ChapterProgress` in `activeChapters`
/// (keyed by chapter index). Phase changes (`enterStage`) clear all
/// per-chapter state so no stale value of a previous phase ever leaks
/// into the next one — the "progress bar stuck at 100 %" bug.
struct RunProgress: Sendable, Equatable {
    struct PhaseInfo: Sendable, Equatable {
        let stage: PipelineStage
        let weight: Double
    }

    /// One actively synthesizing chapter (one entry per parallel worker).
    struct ChapterProgress: Sendable, Equatable {
        var index: Int
        var title: String
        var fraction: Double = 0
        var segmentsDone: Int = 0
        var plannedSegments: Int?
        var audioSeconds: Double = 0
        var startedAt = Date()
    }

    /// A `(timestamp, cumulative value)` pair used for sliding-window
    /// rate estimation (last 60 s) instead of averaging over the whole
    /// phase, which is wildly off after rate changes (model load, pause).
    struct RateSample: Sendable, Equatable {
        let time: Date
        let value: Double
    }

    var startedAt = Date()
    var phases: [PhaseInfo] = []
    var stage: PipelineStage = .extracting
    var phaseStartedAt = Date()
    var phaseFraction: Double = 0
    var detail: String = ""
    var recentLog: [String] = []

    // Image pass
    var imagesDone = 0
    var imagesTotal = 0

    // Summarization
    var llmCallsDone = 0
    var llmCallsTotal = 0
    var llmCharactersDone = 0
    var llmCharactersTotal = 0
    var llmTokensPerSecond: Double?
    var llmRateSamples: [RateSample] = []

    // Synthesis — one entry per active worker, keyed by chapter index.
    var activeChapters: [Int: ChapterProgress] = [:]
    var chapterCount = 0
    var chaptersCompleted = 0
    var synthesisRateSamples: [RateSample] = []
    /// Characters per second of produced audio; starts from a typical
    /// narration rate and is recalibrated from finished chapters.
    var charactersPerAudioSecond: Double = 15
    var chapterCharacterCounts: [Int] = []
    var finishedAudioSeconds: Double = 0
    var synthesisWallSeconds: Double = 0

    // Whole-book ETA inputs, set at run start. Defaults come from the
    // measurements in docs/MESSUNGEN.md and are replaced by the observed
    // speed as soon as a phase has produced enough signal.
    var plannedImages = 0
    var plannedSummaryCharacters = 0
    var plannedNarrationCharacters = 0
    var expectedRealTimeFactor: Double = 0.08
    var defaultSecondsPerImage: Double = 6
    var defaultSummaryCharactersPerSecond: Double = 450

    static func defaultRealTimeFactor(for engine: TTSEngineID) -> Double {
        switch engine {
        case .kokoro: return 0.12
        case .kokoroGerman: return 0.06
        case .kokoroThorsten: return 0.065
        case .piper: return 0.11
        case .supertonic3: return 0.03
        case .omniVoice: return 0.8
        case .appleSystem: return 0.15
        }
    }

    // MARK: - Stage transitions

    /// Enters a new phase and resets *all* per-phase state — chapter
    /// progress, segments, rate samples, detail line. Stage switches are
    /// routed through the coalescer unthrottled so the reset is visible
    /// immediately.
    mutating func enterStage(_ newStage: PipelineStage, detail newDetail: String = "") {
        stage = newStage
        phaseStartedAt = Date()
        phaseFraction = 0
        detail = newDetail
        activeChapters = [:]
        chaptersCompleted = 0
        llmRateSamples = []
        synthesisRateSamples = []
        imagesDone = 0
        imagesTotal = 0
        llmCallsDone = 0
        llmCallsTotal = 0
        llmCharactersDone = 0
        llmCharactersTotal = 0
    }

    // MARK: - Active chapter helpers

    /// The lowest active chapter index — what "current chapter" means
    /// when several workers run in parallel.
    var primaryChapterIndex: Int? {
        activeChapters.keys.min()
    }

    /// Active chapters ordered for display (by chapter index).
    var sortedActiveChapters: [ChapterProgress] {
        activeChapters.values.sorted { $0.index < $1.index }
    }

    /// Audio seconds produced by the currently active chapters.
    var activeAudioSeconds: Double {
        activeChapters.values.reduce(0) { $0 + $1.audioSeconds }
    }

    var producedAudioSeconds: Double { finishedAudioSeconds + activeAudioSeconds }

    // MARK: - Sliding-window rates (last 60 s)

    /// Wall-clock seconds per second of audio, measured over the last
    /// 60 s of samples (lower is faster). Needs a window of at least
    /// 10 s and 2 s of audio so startup spikes don't skew the ETA.
    var windowedRealTimeFactor: Double? {
        windowedRate(samples: synthesisRateSamples)?.inverse
    }

    /// Characters per second over the last 60 s of LLM samples.
    var windowedLLMCharactersPerSecond: Double? {
        windowedRate(samples: llmRateSamples)
    }

    private func windowedRate(samples: [RateSample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.time.timeIntervalSince(first.time)
        let delta = last.value - first.value
        guard seconds >= 10, delta > 0 else { return nil }
        return delta / seconds
    }

    mutating func noteRateSample(value: Double, synthesis: Bool) {
        let sample = RateSample(time: Date(), value: value)
        if synthesis {
            synthesisRateSamples.append(sample)
            pruneSynthesisSamples()
        } else {
            llmRateSamples.append(sample)
            pruneLLMSamples()
        }
    }

    private mutating func pruneSynthesisSamples() {
        let cutoff = Date().addingTimeInterval(-60)
        if let firstKept = synthesisRateSamples.firstIndex(where: { $0.time >= cutoff }) {
            if firstKept > 0 { synthesisRateSamples.removeFirst(firstKept) }
        } else {
            synthesisRateSamples = []
        }
        if synthesisRateSamples.count > 240 { synthesisRateSamples.removeFirst(synthesisRateSamples.count - 240) }
    }

    private mutating func pruneLLMSamples() {
        let cutoff = Date().addingTimeInterval(-60)
        if let firstKept = llmRateSamples.firstIndex(where: { $0.time >= cutoff }) {
            if firstKept > 0 { llmRateSamples.removeFirst(firstKept) }
        } else {
            llmRateSamples = []
        }
        if llmRateSamples.count > 240 { llmRateSamples.removeFirst(llmRateSamples.count - 240) }
    }

    // MARK: - Whole-run ETA

    /// Remaining time for the whole run — current phase plus every phase
    /// still ahead.
    var estimatedTotalRemainingSeconds: TimeInterval? {
        guard stage != .done else { return 0 }
        let phaseElapsed = Date().timeIntervalSince(phaseStartedAt)
        let order = phases.map(\.stage)
        let currentIndex = order.firstIndex(of: stage) ?? -1
        func isAhead(_ s: PipelineStage) -> Bool { (order.firstIndex(of: s) ?? -1) > currentIndex }

        var total = 0.0
        // Images
        if stage == .describingImages {
            let perImage = imagesDone > 0 ? phaseElapsed / Double(imagesDone) : defaultSecondsPerImage
            total += perImage * Double(max(imagesTotal - imagesDone, 0))
        } else if isAhead(.describingImages) {
            total += defaultSecondsPerImage * Double(plannedImages)
        }
        // Summary
        var narrationCharacters = Double(plannedNarrationCharacters)
        if stage == .summarizing {
            let rate = windowedLLMCharactersPerSecond
                ?? ((llmCharactersDone > 0 && phaseElapsed > 1) ? Double(llmCharactersDone) / phaseElapsed : defaultSummaryCharactersPerSecond)
            let remaining = Double(max((llmCharactersTotal > 0 ? llmCharactersTotal : plannedSummaryCharacters) - llmCharactersDone, 0))
            total += remaining / max(rate, 1)
        } else if isAhead(.summarizing) {
            total += Double(plannedSummaryCharacters) / defaultSummaryCharactersPerSecond
        }
        // Synthesis. With fewer than three chapters there is not enough
        // signal for a measured rate — use the engine's default RTF.
        let rtf = chapterCount >= 3
            ? (windowedRealTimeFactor ?? realTimeFactor ?? expectedRealTimeFactor)
            : expectedRealTimeFactor
        if stage == .synthesizing {
            total += max(0, (estimatedTotalAudioSeconds - producedAudioSeconds)) * rtf
            narrationCharacters = Double(chapterCharacterCounts.reduce(0, +))
        } else if isAhead(.synthesizing) {
            total += narrationCharacters / max(charactersPerAudioSecond, 1) * rtf
        }
        // Packaging: roughly proportional to audio length (encode + loudness).
        if stage == .packaging || isAhead(.packaging) {
            total += 5 + narrationCharacters / max(charactersPerAudioSecond, 1) * 0.01
        }
        return total
    }

    static func phases(hasImagePass: Bool, hasSummary: Bool) -> [PhaseInfo] {
        var result = [PhaseInfo(stage: .extracting, weight: 0.02)]
        if hasImagePass { result.append(PhaseInfo(stage: .describingImages, weight: 0.08)) }
        if hasSummary { result.append(PhaseInfo(stage: .summarizing, weight: 0.30)) }
        result.append(PhaseInfo(stage: .synthesizing, weight: 0.0)) // remainder, see below
        result.append(PhaseInfo(stage: .packaging, weight: 0.03))
        let fixed = result.reduce(0) { $0 + $1.weight }
        return result.map { $0.stage == .synthesizing ? PhaseInfo(stage: .synthesizing, weight: max(0.4, 1 - fixed)) : $0 }
    }

    var overallFraction: Double {
        if stage == .done { return 1 }
        let total = phases.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return phaseFraction }
        var accumulated = 0.0
        for phase in phases {
            if phase.stage == stage {
                accumulated += phase.weight * min(max(phaseFraction, 0), 1)
                break
            }
            accumulated += phase.weight
        }
        return min(accumulated / total, 0.999)
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    // MARK: Synthesis estimates

    func estimatedAudioSeconds(forChapter index: Int) -> Double {
        guard chapterCharacterCounts.indices.contains(index) else { return 1 }
        return max(1, Double(chapterCharacterCounts[index]) / max(charactersPerAudioSecond, 1))
    }

    var estimatedTotalAudioSeconds: Double {
        guard !chapterCharacterCounts.isEmpty else { return 0 }
        let primary = primaryChapterIndex ?? chapterCharacterCounts.count
        let remaining = chapterCharacterCounts.indices.dropFirst(primary + 1).reduce(0.0) { $0 + estimatedAudioSeconds(forChapter: $1) }
        let current: Double
        if let active = activeChapters[primary], chapterCharacterCounts.indices.contains(primary) {
            current = max(estimatedAudioSeconds(forChapter: primary), active.audioSeconds)
        } else {
            current = estimatedAudioSeconds(forChapter: primary)
        }
        return finishedAudioSeconds + current + remaining
    }

    /// Synthesis progress by text share: finished chapters' characters
    /// plus every active chapter's fraction. Unlike the audio-based
    /// estimate this doesn't jump back when the chars/second rate gets
    /// recalibrated.
    var synthesisTextFraction: Double {
        let total = chapterCharacterCounts.reduce(0, +)
        guard total > 0 else { return 0 }
        let primary = primaryChapterIndex ?? 0
        let finished = chapterCharacterCounts[..<min(primary, chapterCharacterCounts.count)].reduce(0, +)
        var inFlight = 0.0
        for (index, chapter) in activeChapters where index != primary {
            if chapterCharacterCounts.indices.contains(index) {
                inFlight += Double(chapterCharacterCounts[index]) * min(max(chapter.fraction, 0), 1)
            }
        }
        if chapterCharacterCounts.indices.contains(primary), let active = activeChapters[primary] {
            inFlight += Double(chapterCharacterCounts[primary]) * min(max(active.fraction, 0), 1)
        }
        return min(0.999, (Double(finished) + inFlight) / Double(total))
    }

    /// Wall-clock seconds per second of audio over the whole synthesis
    /// phase so far (lower is faster).
    var realTimeFactor: Double? {
        guard producedAudioSeconds > 5, synthesisWallSeconds > 0 else { return nil }
        return synthesisWallSeconds / producedAudioSeconds
    }

    /// Remaining time for the current phase (and, during synthesis,
    /// packaging is negligible). nil until there's enough signal.
    var estimatedRemainingSeconds: TimeInterval? {
        let phaseElapsed = Date().timeIntervalSince(phaseStartedAt)
        switch stage {
        case .synthesizing:
            let rtf = windowedRealTimeFactor ?? realTimeFactor
            guard let rtf, chapterCount >= 3 else {
                return chapterCount < 3 ? max(0, (estimatedTotalAudioSeconds - producedAudioSeconds) * expectedRealTimeFactor) : nil
            }
            return max(0, (estimatedTotalAudioSeconds - producedAudioSeconds) * rtf)
        case .summarizing:
            if let windowed = windowedLLMCharactersPerSecond {
                return Double(max(llmCharactersTotal - llmCharactersDone, 0)) / windowed
            }
            guard llmCharactersDone > 0, phaseElapsed > 1 else { return nil }
            let rate = Double(llmCharactersDone) / phaseElapsed
            return Double(llmCharactersTotal - llmCharactersDone) / rate
        case .describingImages:
            guard imagesDone > 0 else { return nil }
            return phaseElapsed / Double(imagesDone) * Double(imagesTotal - imagesDone)
        default:
            return nil
        }
    }

    mutating func appendLog(_ line: String) {
        recentLog.append(line)
        if recentLog.count > 12 { recentLog.removeFirst(recentLog.count - 12) }
    }
}

private extension Double {
    /// 1/x, nil-guarded for the RTF inversion.
    var inverse: Double? { self > 0 ? 1 / self : nil }
}

enum DurationFormatter {
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
