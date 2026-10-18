import Foundation
import PDFKit

/// Extracts text from a single PDF page in visual reading order, with a
/// pragmatic heuristic for two-column layouts: PDFKit's own line-by-line
/// selection follows content-stream order, which frequently interleaves the
/// two columns of a paper. We instead bucket lines by horizontal position
/// and, when a clear two-column split is detected, emit the left column in
/// full before the right column.
enum PDFColumnTextExtractor {
    struct Line: Sendable {
        let text: String
        let bounds: CGRect
        /// True when this line is the last line of a paragraph (as opposed
        /// to a mid-paragraph line-wrap). Used to join lines with a real
        /// paragraph break ("\n\n") instead of a bare newline, which matters
        /// downstream: the summarizer only ever splits chunks on paragraph
        /// boundaries, so without this every long PDF chapter looked like
        /// one giant paragraph and got hard-cut at an arbitrary character
        /// offset instead.
        var endsParagraph: Bool = false
    }

    static func extractText(from page: PDFPage) -> String {
        joinedText(orderedLines(on: page))
    }

    static func joinedText(_ lines: [Line]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            if !isLast, let joined = dehyphenatedJoin(line.text, next: lines[index + 1].text) {
                result += joined
                continue
            }
            result += line.text
            if !isLast {
                result += line.endsParagraph ? "\n\n" : "\n"
            }
        }
        return result
    }

    private static let keepHyphenBefore: Set<String> = ["und", "oder", "bzw", "sowie", "bis", "and", "or", "to"]

    /// Line-end hyphenation: "Dif-" + "ferenzierung" → "Differenzierung",
    /// "DNA-" + "Fehler" → "DNA-Fehler" (capitalized continuation = real
    /// compound hyphen), "Ein-" + "und Ausgang" stays "Ein- und". Returns
    /// the line text to emit *without* a following line break, or nil if
    /// the line doesn't end in a word-break hyphen.
    static func dehyphenatedJoin(_ text: String, next: String) -> String? {
        var line = text
        if line.hasSuffix("\u{00AD}") { return String(line.dropLast()) }
        guard line.count >= 3, line.hasSuffix("-") || line.hasSuffix("‐") else { return nil }
        let beforeHyphen = line.dropLast().last
        guard let beforeHyphen, beforeHyphen.isLetter else { return nil }
        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
        guard let nextFirst = nextTrimmed.first, nextFirst.isLetter else { return nil }
        let nextWord = nextTrimmed.split(separator: " ").first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if keepHyphenBefore.contains(nextWord) { return line + " " }
        if nextFirst.isUppercase { return line }
        line.removeLast()
        return line
    }

    /// Same reading-order logic as `extractText`, but exposes the individual
    /// lines (with their vertical position) instead of a flattened string —
    /// needed to slice a single page between two outline entries that both
    /// start on it (common in densely-set two-column papers).
    static func orderedLines(on page: PDFPage) -> [Line] {
        let lines = lineSelections(on: page)
        guard !lines.isEmpty else {
            guard let fallback = page.string, !fallback.isEmpty else { return [] }
            return fallback.components(separatedBy: "\n").map { Line(text: $0, bounds: .zero, endsParagraph: true) }
        }

        if let columnSplit = twoColumnSplit(lines: lines, pageBounds: page.bounds(for: .mediaBox)) {
            return markParagraphEnds(sortedTopToBottom(columnSplit.left)) + markParagraphEnds(sortedTopToBottom(columnSplit.right))
        }

        return markParagraphEnds(sortedTopToBottom(lines))
    }

    /// A line is treated as ending a paragraph when it's noticeably shorter
    /// than the typical (justified) line width in this column — the
    /// standard signal for "this line didn't need to wrap further" that
    /// most PDF-to-text tools rely on. Headings and one-line paragraphs are
    /// correctly caught by the same rule, since they're short too.
    private static func markParagraphEnds(_ lines: [Line], typicalWidthOverride: CGFloat? = nil) -> [Line] {
        guard !lines.isEmpty else { return [] }
        let widths = lines.map { $0.bounds.width }.sorted()
        let typicalWidth = typicalWidthOverride ?? widths[Int(Double(widths.count - 1) * 0.85)]
        guard typicalWidth > 0 else { return lines }

        return lines.enumerated().map { index, line in
            var line = line
            let isLast = index == lines.count - 1
            line.endsParagraph = isLast || line.bounds.width < typicalWidth * 0.82
            return line
        }
    }

    private static func lineSelections(on page: PDFPage) -> [Line] {
        guard let pageSelection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        let lineSelections = pageSelection.selectionsByLine()
        return lineSelections.compactMap { selection -> Line? in
            guard let raw = selection.string?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            let text = PDFTextbookCleaner.normalizeLineText(raw)
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return Line(text: text, bounds: bounds)
        }
    }

    private static func sortedTopToBottom(_ lines: [Line]) -> [Line] {
        lines.sorted { $0.bounds.midY > $1.bounds.midY }
    }

    private struct ColumnSplit {
        let left: [Line]
        let right: [Line]
    }

    /// Simple 1D two-cluster split on line midpoints. Only reports a split
    /// when both clusters are substantial and clearly separated, so normal
    /// single-column pages (including ones with occasional indented lines,
    /// e.g. block quotes) are left alone.
    private static func twoColumnSplit(lines: [Line], pageBounds: CGRect) -> ColumnSplit? {
        guard lines.count >= 12, pageBounds.width > 0 else { return nil }

        let midpoints = lines.map { $0.bounds.midX }.sorted()
        let pageMid = pageBounds.midX

        var leftCluster: [Double] = []
        var rightCluster: [Double] = []
        for value in midpoints {
            if value < pageMid {
                leftCluster.append(value)
            } else {
                rightCluster.append(value)
            }
        }

        let minClusterFraction = 0.25
        guard Double(leftCluster.count) >= Double(lines.count) * minClusterFraction,
              Double(rightCluster.count) >= Double(lines.count) * minClusterFraction else {
            return nil
        }

        guard let leftMax = leftCluster.max(), let rightMin = rightCluster.min() else { return nil }
        let gap = rightMin - leftMax
        // A real two-column academic gutter can be narrower than 6% of page
        // width — a measured real case had a genuine, well-balanced two
        // column split (50/46 lines) with only a 5.5%-of-width gutter,
        // which a 6% threshold rejected outright. That silently fell back
        // to sorting the whole page by Y position alone, interleaving the
        // two columns by height instead of reading left column then right —
        // scrambling the actual narration order, not just chapter splitting.
        // The balanced-cluster-size check above already does most of the
        // work guarding against false positives on genuine single-column
        // pages, so this can afford to be more permissive.
        let requiredGap = pageBounds.width * 0.04
        guard gap >= requiredGap else { return nil }

        let boundary = (leftMax + rightMin) / 2
        let left = lines.filter { $0.bounds.midX < boundary }
        let right = lines.filter { $0.bounds.midX >= boundary }
        return ColumnSplit(left: left, right: right)
    }
}
