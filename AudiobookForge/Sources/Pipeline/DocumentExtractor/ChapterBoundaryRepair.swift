import Foundation

/// Sentence-boundary repair across chapter splits (plan 6.5, rule 3).
///
/// When a chapter begins mid-sentence (lowercase first character) and the
/// previous chapter ends without sentence punctuation, the sentence rest
/// belongs to the previous chapter — otherwise the TTS reads a fragment
/// with falling intonation and every AI title built on that fragment is
/// wrong. Runs once at import, after extraction and merging; text moves
/// only between adjacent chapters, nothing is deleted.
enum ChapterBoundaryRepair {
    /// Characters that end a sentence well enough that the next chapter
    /// may legitimately start lowercase (rare, but e.g. after a quoted
    /// fragment).
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":", "—", "\"", "”", "›", "»", ")"]

    static func firstLetterIsLowercase(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first.isLowercase
    }

    /// Moves mid-sentence fragments from each chapter's start to the end
    /// of its predecessor. Repeats until stable (a repair can expose the
    /// next one).
    static func repairBoundaries(chapters: [Chapter]) -> [Chapter] {
        guard chapters.count > 1 else { return chapters }
        var result = chapters

        for index in result.indices.dropFirst() {
            let previous = result[index - 1]
            let current = result[index]
            guard let split = fragmentEnd(in: current.cleanedText),
                  firstLetterIsLowercase(current.cleanedText),
                  let last = previous.cleanedText.last(where: { !$0.isWhitespace }),
                  !sentenceEnds.contains(last)
            else { continue }

            let fragment = String(current.cleanedText[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { continue }

            let remaining = String(current.cleanedText[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // The fragment moves to the predecessor (rawText mirrors
            // cleanedText when the extraction produced no separate raw).
            var fixedPrevious = previous
            fixedPrevious.cleanedText = (previous.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines) + " " + fragment)
            if previous.rawText == previous.cleanedText { fixedPrevious.rawText = fixedPrevious.cleanedText }
            result[index - 1] = fixedPrevious

            var fixedCurrent = current
            fixedCurrent.cleanedText = remaining
            if current.rawText == current.cleanedText { fixedCurrent.rawText = remaining }
            result[index] = fixedCurrent
        }
        return result
    }

    /// End index of the leading fragment: the first sentence end, or the
    /// first paragraph break, whichever comes first.
    private static func fragmentEnd(in text: String) -> String.Index? {
        guard let firstEnd = text.firstIndex(where: { ".!?".contains($0) }) else {
            return text.firstIndex(of: "\n")
        }
        var end = text.index(after: firstEnd)
        if end < text.endIndex, "\"”›»)".contains(text[end]) { end = text.index(after: end) }
        return end
    }

}
