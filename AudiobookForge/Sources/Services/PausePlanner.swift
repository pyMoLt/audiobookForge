import Foundation

/// App-side pause planning (plan 8.4), engine-independent: the narration
/// text is split into segments that carry the kind of boundary FOLLOWS
/// them, and every segment kind maps to a pause length from settings.
/// Engines then insert silence themselves (bridges via `--pauses-json`,
/// Piper via zero bytes into the encoder) so read-along timing stays exact.
///
/// Jitter is deterministic per chapter+segment: regenerating a chapter
/// produces byte-identical audio, and two parallel workers never jitter the
/// same sentence the same way.
enum SegmentKind: String, Codable, Sendable, Equatable {
    /// Sentence inside a paragraph — the engine's own natural gap is
    /// usually fine (default 0 = no extra pause).
    case sentence
    /// Last sentence of a paragraph.
    case paragraphEnd
    /// A heading line.
    case heading
    /// Last sentence of a list item.
    case listItem
    /// Last sentence of a figure description block.
    case figure
}

struct PlannedSegment: Equatable, Sendable {
    let text: String
    let kind: SegmentKind
}

/// JSON payload handed to the bridges via `--pauses-json`.
struct PausePlan: Codable, Sendable, Equatable {
    /// Silence before the first segment (chapter lead-in).
    var leadInMs: Int
    /// Silence after the last segment (chapter tail).
    var tailMs: Int
    /// Pause after segment i (missing/trailing entries = 0).
    var pauseAfterMs: [Int]
}

enum PausePlanner {
    static let bulletMarkers: Set<String> = ["•", "▪", "●", "■", "□", "▸", "▶", "‣"]

    /// Splits narration text into planned segments in reading order.
    static func plan(_ text: String) -> [PlannedSegment] {
        var segments: [PlannedSegment] = []
        let paragraphs = text.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let sentences = SentenceSplitter.split(trimmed)
            guard !sentences.isEmpty else { continue }

            // Order matters: a numbered list item ("1. Erster Punkt") also
            // looks like a heading to the heuristic, so list items win.
            let kind: SegmentKind
            if isListItemLine(trimmed) {
                kind = .listItem
            } else if isFigureLine(trimmed) {
                kind = .figure
            } else if isHeadingLine(trimmed) {
                kind = .heading
            } else {
                kind = .paragraphEnd
            }

            // A heading is its own segment as a whole (usually a single
            // short line); everything else is sentence-wise with the
            // paragraph's boundary kind on its LAST sentence.
            if kind == .heading {
                segments.append(PlannedSegment(text: trimmed, kind: .heading))
                continue
            }
            for (index, sentence) in sentences.enumerated() {
                let segmentKind = index == sentences.count - 1 ? kind : .sentence
                segments.append(PlannedSegment(text: sentence, kind: segmentKind))
            }
        }
        return segments
    }

    /// Builds the full bridge payload for a chapter: lead-in/tail plus a
    /// per-segment pause (jittered, deterministic). `determinismKey` is
    /// stable across regenerations of the same chapter (engines use the
    /// chapter's output file path) so re-synthesized chapters sound
    /// identical.
    static func pausePlan(for segments: [PlannedSegment], determinismKey: String, settings: AppSettings) -> PausePlan {
        let pauses = segments.enumerated().map { index, segment in
            jitteredPauseMs(kind: segment.kind, determinismKey: determinismKey, segmentIndex: index, settings: settings)
        }
        return PausePlan(
            leadInMs: max(0, settings.chapterLeadInMs),
            tailMs: max(0, settings.chapterTailMs),
            pauseAfterMs: pauses
        )
    }

    static func pausePlan(for text: String, determinismKey: String, settings: AppSettings) -> PausePlan {
        pausePlan(for: plan(text), determinismKey: determinismKey, settings: settings)
    }

    /// True when the plan would add any silence at all — engines skip the
    /// pauses file entirely in that case (bit-identical old behavior).
    static func containsSilence(_ plan: PausePlan) -> Bool {
        plan.leadInMs > 0 || plan.tailMs > 0 || plan.pauseAfterMs.contains { $0 > 0 }
    }

    /// Pause length for a segment kind (before jitter).
    static func basePauseMs(kind: SegmentKind, settings: AppSettings) -> Int {
        switch kind {
        case .sentence: return max(0, settings.sentencePauseMs)
        case .paragraphEnd: return max(0, settings.paragraphPauseMs)
        case .heading: return max(0, settings.headingPauseMs)
        case .listItem: return max(0, settings.listItemPauseMs)
        case .figure: return max(0, settings.figurePauseMs)
        }
    }

    /// Jittered pause, deterministic for (seed, segment) so regenerated
    /// chapters sound identical. A base of 0 stays 0 — the engine's
    /// natural gap is never "improved" by jitter.
    static func jitteredPauseMs(kind: SegmentKind, determinismKey: String, segmentIndex: Int, settings: AppSettings) -> Int {
        let base = basePauseMs(kind: kind, settings: settings)
        guard base > 0, settings.pauseJitterPercent > 0 else { return base }
        let amplitude = Double(base) * Double(settings.pauseJitterPercent) / 100.0
        let unit = deterministicUnit(seed: determinismKey, segmentIndex: segmentIndex)
        let jitter = (unit * 2.0 - 1.0) * amplitude
        return max(0, Int((Double(base) + jitter).rounded()))
    }

    /// Stable pseudo-random value in [0, 1) from the seed + segment index
    /// (splitmix64-style mixing — no seeded RNG state involved).
    private static func deterministicUnit(seed: String, segmentIndex: Int) -> Double {
        var hash: UInt64 = 0x9E3779B97F4A7C15
        for byte in Data(seed.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0xBF58476D1CE4E5B9
            hash = (hash << 7) | (hash >> 57)
        }
        hash ^= UInt64(bitPattern: Int64(segmentIndex))
        hash = (hash ^ (hash >> 30)) &* 0xBF58476D1CE4E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D049BB133111EB
        hash ^= hash >> 31
        return Double(hash % 100_000) / 100_000.0
    }

    // MARK: - Line classification

    /// A heading-like paragraph: one short line without sentence-ending
    /// punctuation (mirrors the summarizer's topic-boundary heuristic).
    static func isHeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !trimmed.contains("\n") else { return false }
        if let last = trimmed.last, ".!?;:,".contains(last) { return false }
        return trimmed.first?.isLetter == true
            || (trimmed.first?.isNumber == true && trimmed.contains(where: \.isLetter))
    }

    /// A list item: starts with a bullet marker or a numbering like "1." /
    /// "1)" / "- " / "* ".
    static func isListItemLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if bulletMarkers.contains(String(first)) { return true }
        if first == "-" || first == "*" || first == "–" || first == "—" {
            return trimmed.dropFirst().first == " "
        }
        if let match = trimmed.range(of: #"^\d{1,3}[.)](\s|$)"#, options: .regularExpression) {
            return match.lowerBound == trimmed.startIndex
        }
        return false
    }

    /// A figure description block inserted by the vision pass.
    static func isFigureLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("Abbildung:") || trimmed.hasPrefix("Figure:")
    }
}
