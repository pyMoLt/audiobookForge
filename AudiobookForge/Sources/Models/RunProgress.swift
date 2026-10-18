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
struct RunProgress: Sendable, Equatable {
    struct PhaseInfo: Sendable, Equatable {
        let stage: PipelineStage
        let weight: Double
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

    // Synthesis
    var chapterIndex = 0
    var chapterCount = 0
    var chapterTitle = ""
    var chapterFraction: Double = 0
    var plannedSegments: Int?
    var segmentsDone = 0
    /// Characters per second of produced audio; starts from a typical
    /// narration rate and is recalibrated from finished chapters.
    var charactersPerAudioSecond: Double = 15
    var chapterCharacterCounts: [Int] = []
    var finishedAudioSeconds: Double = 0
    var currentChapterAudioSeconds: Double = 0
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
        }
    }

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
            let rate = (llmCharactersDone > 0 && phaseElapsed > 1) ? Double(llmCharactersDone) / phaseElapsed : defaultSummaryCharactersPerSecond
            let remaining = Double(max((llmCharactersTotal > 0 ? llmCharactersTotal : plannedSummaryCharacters) - llmCharactersDone, 0))
            total += remaining / max(rate, 1)
        } else if isAhead(.summarizing) {
            total += Double(plannedSummaryCharacters) / defaultSummaryCharactersPerSecond
        }
        // Synthesis
        let rtf = realTimeFactor ?? expectedRealTimeFactor
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
        var result: [PhaseInfo] = [PhaseInfo(stage: .extracting, weight: 0.02)]
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
        let remaining = chapterCharacterCounts.indices.dropFirst(chapterIndex + 1).reduce(0.0) { $0 + estimatedAudioSeconds(forChapter: $1) }
        let current = max(estimatedAudioSeconds(forChapter: chapterIndex), currentChapterAudioSeconds)
        return finishedAudioSeconds + current + remaining
    }

    var producedAudioSeconds: Double { finishedAudioSeconds + currentChapterAudioSeconds }

    /// Synthesis progress by text share: finished chapters' characters plus
    /// the current chapter's fraction. Unlike the audio-based estimate this
    /// doesn't jump back when the chars/second rate gets recalibrated.
    var synthesisTextFraction: Double {
        let total = chapterCharacterCounts.reduce(0, +)
        guard total > 0, chapterCharacterCounts.indices.contains(chapterIndex) else { return 0 }
        let finished = chapterCharacterCounts[..<chapterIndex].reduce(0, +)
        let current = Double(chapterCharacterCounts[chapterIndex]) * min(max(chapterFraction, 0), 1)
        return min(0.999, (Double(finished) + current) / Double(total))
    }

    /// Wall-clock seconds per second of audio (lower is faster).
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
            guard let rtf = realTimeFactor else { return nil }
            return max(0, (estimatedTotalAudioSeconds - producedAudioSeconds) * rtf)
        case .summarizing:
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
