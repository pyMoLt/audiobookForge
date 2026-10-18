import Foundation
import CoreGraphics

/// Filters the parts of an academic-paper-style PDF that shouldn't be
/// narrated: repository letterheads ("NIH Public Access", "HHS Public
/// Access" — the standard PMC author-manuscript banner, extremely common on
/// NIH-funded biomedical papers), the author-name/affiliation block between
/// the title and the abstract, and small-font footnote text (reprint
/// contact info, funding acknowledgments) at the bottom of pages.
enum PDFFrontMatterFilter {
    /// Repository/journal boilerplate that recurs, near-verbatim, across a
    /// large fraction of real-world reprints. Checked case-insensitively.
    /// Deliberately narrow — only phrases that are unambiguously boilerplate
    /// and would never legitimately be the tallest/most prominent text of
    /// an actual paper title.
    private static let boilerplatePhrases = [
        "public access", "author manuscript", "pubmed central",
        "national institutes of health", "sciencedirect", "elsevier",
    ]

    static func isBoilerplate(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return boilerplatePhrases.contains { lowered.contains($0) }
    }

    /// Drops lines that are meaningfully smaller than the page's own
    /// dominant (most common) text size — footnotes, reprint request
    /// addresses, funding acknowledgments, figure/table captions in reduced
    /// type. Deliberately not restricted to the bottom of the page: small
    /// print can appear inline (inter-column footnote markers, marginal
    /// notes) too. Never drops same-size-or-larger text, so headings (which
    /// are usually bigger than body text, never smaller) are unaffected.
    static func filterFootnoteLines(_ lines: [PDFColumnTextExtractor.Line], pageBounds: CGRect) -> [PDFColumnTextExtractor.Line] {
        guard lines.count >= 6 else { return lines }
        guard let dominant = dominantHeight(of: lines), dominant > 0 else { return lines }
        // Synthetic lines (figure placeholders) have no geometry — keep them.
        return lines.filter { $0.bounds == .zero || $0.bounds.height >= dominant * 0.75 }
    }

    /// Some PDF producers (notably PMC/NIH's auto-generated "author
    /// manuscript" reprints) emit a flat outline where the letterhead,
    /// "Published in final edited form as," and even author names (with a
    /// stray affiliation-superscript digit stuck to the end, e.g.
    /// "Yamashita1") show up as their own bookmark entries alongside real
    /// section headings. Dropping these entries before building chapters
    /// folds their (junk) text into whichever neighboring real section
    /// ends up spanning that range, instead of giving each a standalone,
    /// seconds-long "chapter."
    static func isJunkOutlineLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if isBoilerplate(trimmed) { return true }
        if trimmed.range(of: #"^published in .* form as:?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // A short label ending in a digit with no preceding space/punctuation
        // is almost always a name with a merged-in affiliation superscript
        // ("Yamashita1", "Smith2,3") rather than a real section heading —
        // real headings essentially never end this way.
        if trimmed.count <= 40, trimmed.range(of: #"[A-Za-z][\d,]+$"#, options: [.regularExpression]) != nil { return true }
        return false
    }

    /// Trims title-page front matter (letterhead, title, author names,
    /// affiliations, journal/DOI metadata) from the very front of the
    /// document — general-purpose, not specific to academic papers: a book
    /// converted from print, a report, a scanned pamphlet all have the same
    /// shape (a handful of short/differently-sized lines before the real
    /// prose begins), even though none of them say "Abstract."
    ///
    /// Two signals are combined, first match wins:
    /// 1. A short, standalone "Abstract" heading (cheap, unambiguous,
    ///    common enough in papers to be worth a fast path).
    /// 2. Format-agnostic: the first point where several consecutive lines
    ///    all match the document's own dominant body-text size and width —
    ///    i.e., where real wrapped paragraphs actually start. Title/author/
    ///    affiliation lines are almost always shorter or a different size
    ///    than body text, so this reliably finds "where prose begins"
    ///    regardless of document type or language. If body text already
    ///    starts at line 0 (no front matter at all), this is a safe no-op.
    static func trimFrontMatter(pageLines: [[PDFColumnTextExtractor.Line]]) -> [[PDFColumnTextExtractor.Line]] {
        if let abstractTrim = trimBeforeAbstractHeading(pageLines: pageLines) {
            return abstractTrim
        }
        return trimBeforeBodyTextRun(pageLines: pageLines)
    }

    private static func trimBeforeAbstractHeading(pageLines: [[PDFColumnTextExtractor.Line]]) -> [[PDFColumnTextExtractor.Line]]? {
        let searchPageCount = min(2, pageLines.count)
        for pageIndex in 0..<searchPageCount {
            let lines = pageLines[pageIndex]
            for (lineIndex, line) in lines.enumerated() {
                guard isAbstractHeading(line.text) else { continue }
                var result = pageLines
                for earlierPage in 0..<pageIndex { result[earlierPage] = [] }
                result[pageIndex] = Array(lines[(lineIndex + 1)...])
                return result
            }
        }
        return nil
    }

    private static func isAbstractHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 15 else { return false }
        return trimmed.range(of: #"^abstract\.?:?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Required number of consecutive body-sized, body-width lines before
    /// we trust "this is where the real text starts". Kept fairly low (a
    /// paragraph's last line is always short, which caps how long a
    /// same-height "wide line" run can realistically get for a short
    /// opening paragraph) while still being a strong signal — two
    /// consecutive full-column-width lines at body size essentially never
    /// happens for names/addresses/imprint lines.
    private static let bodyRunLength = 3
    /// How far into page 1 we're willing to search — bounds how much could
    /// ever be trimmed, so a misfire can't eat real content.
    private static let maxSearchLines = 60

    private static func trimBeforeBodyTextRun(pageLines: [[PDFColumnTextExtractor.Line]]) -> [[PDFColumnTextExtractor.Line]] {
        guard let firstPage = pageLines.first, !firstPage.isEmpty else { return pageLines }

        // The dominant body size is estimated from page 2 when available —
        // page 1 is exactly the page whose composition we don't trust yet,
        // whereas an inner page is overwhelmingly likely to be plain prose.
        let referencePage = pageLines.count > 1 && !pageLines[1].isEmpty ? pageLines[1] : firstPage
        guard let bodyHeight = dominantHeight(of: referencePage) else { return pageLines }
        let bodyWidthReference = referencePage.map(\.bounds.width).max() ?? 0
        guard bodyWidthReference > 0 else { return pageLines }

        let searchLimit = min(firstPage.count, maxSearchLines)
        for startIndex in 0..<max(0, searchLimit - bodyRunLength + 1) {
            let window = firstPage[startIndex..<(startIndex + bodyRunLength)]
            let allMatch = window.allSatisfy { line in
                abs(line.bounds.height - bodyHeight) < 1.0 && line.bounds.width > bodyWidthReference * 0.55
            }
            if allMatch {
                guard startIndex > 0 else { return pageLines } // body already starts at the top — nothing to trim
                var result = pageLines
                result[0] = Array(firstPage[startIndex...])
                return result
            }
        }
        return pageLines
    }

    private static func dominantHeight(of lines: [PDFColumnTextExtractor.Line]) -> CGFloat? {
        guard !lines.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for line in lines {
            let rounded = Int((line.bounds.height * 2).rounded()) // bucket to half-points
            counts[rounded, default: 0] += 1
        }
        guard let mode = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return CGFloat(mode) / 2
    }
}
