import Foundation
import PDFKit

/// Page-level cleanup aimed at figure-heavy, atypically laid out books
/// (textbooks, lecture scripts): figure label text, captions, figure
/// placement, running heads, page numbers and margin tabs. Verified against
/// a 714-page histology textbook where, before this pass, ~4 600 figure
/// labels ("rER", "N*", "a b"), running heads and thumb-tab digits ended
/// up in the narration and even became chapter titles.
enum PDFTextbookCleaner {
    struct Options {
        var removeFigureLabels = true
        var keepCaptions = true
        var insertFigurePlaceholders = true
        var thresholds = PDFFigureDetector.Thresholds()
    }

    struct PageResult {
        var lines: [PDFColumnTextExtractor.Line]
        var figureCount: Int
    }

    // MARK: Per page: figures, labels, captions, placeholders

    static func process(page: PDFPage, pageIndex: Int, lines: [PDFColumnTextExtractor.Line], options: Options) -> PageResult {
        var figures = PDFFigureDetector.figures(on: page, lines: lines, thresholds: options.thresholds)
        var lines = lines
        let pageBounds = page.bounds(for: .mediaBox)
        for cluster in labelClusters(in: lines) {
            // Labels set around a picture (with leader lines) belong to it:
            // grow that figure instead of creating a second one.
            if let near = figures.firstIndex(where: { $0.rect.insetBy(dx: -40, dy: -40).intersects(cluster) }) {
                figures[near].rect = figures[near].rect.union(cluster.insetBy(dx: -4, dy: -4)).intersection(pageBounds)
                continue
            }
            let rect = cluster.insetBy(dx: -18, dy: -18).intersection(pageBounds)
            guard rect.width * rect.height >= pageBounds.width * pageBounds.height * options.thresholds.minimumAreaFraction else { continue }
            figures.append(PDFFigureDetector.Figure(rect: rect, kind: .vector, pixelWidth: Int(rect.width * 2), pixelHeight: Int(rect.height * 2), encodedBytes: Int.max))
        }
        figures = PDFFigureDetector.mergeOverlapping(figures)

        // Captions (also find figures the geometry pass missed: a caption
        // with no detected figure next to it still marks one).
        let captions = findCaptions(in: lines)
        var captionForFigure: [Int: CaptionSpan] = [:]
        for caption in captions {
            if let figureIndex = nearestFigure(to: caption, in: figures, lines: lines) {
                if captionForFigure[figureIndex] == nil { captionForFigure[figureIndex] = caption }
            } else if let rect = inferredFigureRect(for: caption, lines: lines, page: page) {
                figures.append(PDFFigureDetector.Figure(rect: rect, kind: .vector, pixelWidth: Int(rect.width * 2), pixelHeight: Int(rect.height * 2), encodedBytes: Int.max))
                captionForFigure[figures.count - 1] = caption
            }
        }

        // Drop label-like text inside figures (never prose, never captions).
        let captionLineIndices = Set(captions.flatMap { Array($0.range) })
        var removed = Set<Int>()
        if options.removeFigureLabels {
            for (index, line) in lines.enumerated() where !captionLineIndices.contains(index) {
                let center = CGPoint(x: line.bounds.midX, y: line.bounds.midY)
                if figures.contains(where: { $0.rect.insetBy(dx: -6, dy: -6).contains(center) }), PDFFigureDetector.isLabelLike(line.text) {
                    removed.insert(index)
                }
            }
        }
        if !options.keepCaptions {
            removed.formUnion(captionLineIndices)
        }

        // Where each figure's placeholder goes (index of the line it
        // follows; -1 = before the first line), always at a paragraph end.
        var insertions: [(after: Int, text: String)] = []
        if options.insertFigurePlaceholders {
            for (figureIndex, figure) in figures.enumerated() {
                let caption = captionForFigure[figureIndex]
                let after: Int
                if let caption {
                    after = caption.range.upperBound - 1
                } else {
                    after = paragraphEnd(afterFigure: figure.rect, lines: lines, removed: removed)
                }
                let reference = FigureReference(
                    source: .pdf,
                    page: pageIndex,
                    rect: [figure.rect.minX, figure.rect.minY, figure.rect.width, figure.rect.height].map { Double($0) },
                    kind: figure.kind.rawValue,
                    caption: caption.map { span in span.range.map { lines[$0].text }.joined(separator: " ") }.map { String($0.prefix(600)) },
                    pixelWidth: figure.pixelWidth,
                    pixelHeight: figure.pixelHeight,
                    encodedBytes: figure.encodedBytes == Int.max ? nil : figure.encodedBytes
                )
                insertions.append((after, ImageDescriptionMarker.placeholder(for: reference)))
            }
        }

        var output: [PDFColumnTextExtractor.Line] = []
        let sortedInsertions = insertions.sorted { $0.after < $1.after }
        for insertion in sortedInsertions where insertion.after < 0 {
            output.append(PDFColumnTextExtractor.Line(text: insertion.text, bounds: .zero, endsParagraph: true))
        }
        for (index, line) in lines.enumerated() {
            if !removed.contains(index) { output.append(line) }
            let here = sortedInsertions.filter { $0.after == index }
            if !here.isEmpty {
                if var last = output.popLast() {
                    last.endsParagraph = true
                    output.append(last)
                }
                for insertion in here {
                    output.append(PDFColumnTextExtractor.Line(text: insertion.text, bounds: .zero, endsParagraph: true))
                }
            }
        }
        lines = output
        return PageResult(lines: lines, figureCount: figures.count)
    }

    /// Very short, non-sentence text ("EZR", "Na+", "IV*", "ZO").
    static func isTinyLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 6, trimmed.split(separator: " ").count <= 2 else { return false }
        if let last = trimmed.last, ".!?".contains(last), trimmed.count > 2 { return false }
        return true
    }

    /// Bounding boxes of places where at least three tiny labels sit close
    /// together — the signature of a drawn schema whose graphics the path
    /// scan didn't capture as one figure.
    static func labelClusters(in lines: [PDFColumnTextExtractor.Line]) -> [CGRect] {
        let labels = lines.filter { $0.bounds != .zero && isTinyLabel($0.text) }.map(\.bounds)
        var clusters: [(rect: CGRect, count: Int)] = []
        for rect in labels {
            var current = (rect: rect, count: 1)
            var index = 0
            while index < clusters.count {
                if clusters[index].rect.insetBy(dx: -60, dy: -45).intersects(current.rect) {
                    current = (current.rect.union(clusters[index].rect), current.count + clusters[index].count)
                    clusters.remove(at: index)
                    index = 0
                } else {
                    index += 1
                }
            }
            clusters.append(current)
        }
        return clusters.filter { $0.count >= 3 }.map(\.rect)
    }

    struct CaptionSpan {
        let range: Range<Int>
        let bounds: CGRect
        let isTable: Bool
    }

    /// A caption starts with "Abb. 6.8", "Figure 3", "Tab. 2.1" … and runs
    /// to the end of its paragraph (max. 15 lines).
    static func findCaptions(in lines: [PDFColumnTextExtractor.Line]) -> [CaptionSpan] {
        var spans: [CaptionSpan] = []
        var index = 0
        while index < lines.count {
            let text = lines[index].text
            guard PDFFigureDetector.isCaptionStart(text), lines[index].bounds != .zero else { index += 1; continue }
            var end = index
            while end < lines.count - 1, !lines[end].endsParagraph, end - index < 15 { end += 1 }
            let bounds = lines[index...end].map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            let lower = text.lowercased()
            spans.append(CaptionSpan(range: index..<(end + 1), bounds: bounds, isTable: lower.hasPrefix("tab")))
            index = end + 1
        }
        return spans
    }

    private static func nearestFigure(to caption: CaptionSpan, in figures: [PDFFigureDetector.Figure], lines: [PDFColumnTextExtractor.Line]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, figure) in figures.enumerated() {
            let horizontalOverlap = min(figure.rect.maxX, caption.bounds.maxX) - max(figure.rect.minX, caption.bounds.minX)
            guard horizontalOverlap > 0 || abs(figure.rect.midY - caption.bounds.midY) < figure.rect.height / 2 else { continue }
            let below = figure.rect.minY - caption.bounds.maxY   // caption under the figure
            let above = caption.bounds.minY - figure.rect.maxY   // caption over the figure (tables)
            let side = horizontalOverlap <= 0 ? abs(caption.bounds.minX - figure.rect.maxX) : .greatestFiniteMagnitude
            let distance = min(below >= -6 ? below : .greatestFiniteMagnitude, above >= -6 ? above : .greatestFiniteMagnitude, side)
            guard distance <= 70 else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// Region a caption most likely belongs to when no figure was detected
    /// there: between the caption and the nearest prose above it (below it
    /// for table captions), spanning the caption's column.
    private static func inferredFigureRect(for caption: CaptionSpan, lines: [PDFColumnTextExtractor.Line], page: PDFPage) -> CGRect? {
        let pageBounds = page.bounds(for: .mediaBox)
        // The figure usually spans the whole text column, not just the
        // (often shorter) caption line.
        let captionRange = (minX: caption.bounds.minX - 4, maxX: caption.bounds.maxX + 4)
        let prose = lines.enumerated().filter { index, line in
            !caption.range.contains(index) && line.bounds != .zero && !PDFFigureDetector.isLabelLike(line.text)
                && line.bounds.maxX > captionRange.minX && line.bounds.minX < captionRange.maxX
        }.map(\.element)
        let column = (minX: min(captionRange.minX, prose.map(\.bounds.minX).min() ?? captionRange.minX),
                      maxX: max(captionRange.maxX, prose.map(\.bounds.maxX).max() ?? captionRange.maxX))
        let rect: CGRect
        if caption.isTable {
            let floor = prose.filter { $0.bounds.maxY < caption.bounds.minY }.map(\.bounds.maxY).max() ?? pageBounds.minY + pageBounds.height * 0.08
            rect = CGRect(x: column.minX, y: floor, width: column.maxX - column.minX, height: caption.bounds.minY - floor)
        } else {
            let ceiling = prose.filter { $0.bounds.minY > caption.bounds.maxY }.map(\.bounds.minY).min() ?? pageBounds.maxY - pageBounds.height * 0.08
            rect = CGRect(x: column.minX, y: caption.bounds.maxY, width: column.maxX - column.minX, height: ceiling - caption.bounds.maxY)
        }
        return rect.height >= 60 ? rect : nil
    }

    /// Index of the line after which a figure without caption is narrated:
    /// the paragraph end at or after the last prose line above the figure
    /// in its column (so a sentence is never cut in half).
    private static func paragraphEnd(afterFigure rect: CGRect, lines: [PDFColumnTextExtractor.Line], removed: Set<Int>) -> Int {
        let overlapping = lines.indices.filter { index in
            !removed.contains(index) && lines[index].bounds != .zero
                && lines[index].bounds.maxX > rect.minX && lines[index].bounds.minX < rect.maxX
        }
        guard let lastAbove = overlapping.last(where: { lines[$0].bounds.midY > rect.maxY }) else {
            return (overlapping.first ?? 0) - 1
        }
        var index = lastAbove
        while index < lines.count - 1, !lines[index].endsParagraph { index += 1 }
        return index
    }

    // MARK: Across pages: running heads, page numbers, margin tabs

    /// Removes running heads (short lines in the top band that recur on
    /// at least two pages), bare page numbers in the top/bottom band, and
    /// thumb-tab marks (1–3 characters hugging the outer page edge).
    static func removePageFurniture(pageLines: [[PDFColumnTextExtractor.Line]], pageBounds: [CGRect]) -> [[PDFColumnTextExtractor.Line]] {
        func normalized(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter }
        }
        var topCounts: [String: Int] = [:]
        var bottomCounts: [String: Int] = [:]
        for (pageIndex, lines) in pageLines.enumerated() {
            let bounds = pageBounds[pageIndex]
            var seenTop = Set<String>(), seenBottom = Set<String>()
            for line in lines where line.bounds != .zero {
                let key = normalized(line.text)
                guard key.count >= 3 else { continue }
                if line.bounds.minY > bounds.maxY - bounds.height * 0.09 { seenTop.insert(key) }
                if line.bounds.maxY < bounds.minY + bounds.height * 0.09 { seenBottom.insert(key) }
            }
            seenTop.forEach { topCounts[$0, default: 0] += 1 }
            seenBottom.forEach { bottomCounts[$0, default: 0] += 1 }
        }

        return pageLines.enumerated().map { pageIndex, lines in
            let bounds = pageBounds[pageIndex]
            return lines.enumerated().filter { index, line in
                guard line.bounds != .zero else { return true }
                let text = line.text.trimmingCharacters(in: .whitespaces)
                let key = normalized(text)
                let inTop = line.bounds.minY > bounds.maxY - bounds.height * 0.09
                let inBottom = line.bounds.maxY < bounds.minY + bounds.height * 0.09
                let isPageNumber = text.range(of: #"^[\divxlcIVXLC]{1,5}$"#, options: .regularExpression) != nil
                // A lone number directly above a much larger title is a
                // chapter number ("1" / "Grundlagen der Pharmakologie"),
                // not a page number.
                let followedByLargeTitle = index + 1 < lines.count
                    && lines[index + 1].bounds.height >= line.bounds.height * 1.6
                    && lines[index + 1].text.contains(where: \.isLetter)
                if (inTop || inBottom) && isPageNumber && !followedByLargeTitle { return false }
                if inTop, key.count >= 3, line.text.count <= 90, topCounts[key, default: 0] >= 2 { return false }
                if inBottom, key.count >= 3, bottomCounts[key, default: 0] >= 3 { return false }
                // Stray punctuation lines ("," "-" "–") left by figure labels.
                if !text.contains(where: { $0.isLetter || $0.isNumber }) { return false }
                let hugsEdge = line.bounds.minX < bounds.minX + bounds.width * 0.07 || line.bounds.maxX > bounds.maxX - bounds.width * 0.07
                if hugsEdge, text.count <= 3, line.bounds.width < bounds.width * 0.06, !followedByLargeTitle { return false }
                return true
            }.map(\.element)
        }
    }

    // MARK: Figures at a page break

    /// When a page ends mid-sentence and the next page opens with a figure
    /// and/or its caption, the sentence's continuation follows only after
    /// them. Moves those leading figure/caption lines behind the end of the
    /// continued paragraph so the sentence is narrated in one piece.
    static func moveFiguresBehindPageBreakSentences(_ pageLines: [[PDFColumnTextExtractor.Line]]) -> [[PDFColumnTextExtractor.Line]] {
        var result = pageLines
        for pageIndex in 1..<max(result.count, 1) {
            guard let lastProse = result[pageIndex - 1].last(where: { !ImageDescriptionMarker.hasPlaceholders(in: $0.text) }) else { continue }
            let ending = lastProse.text.trimmingCharacters(in: .whitespaces)
            guard let lastChar = ending.last, !".!?:“\")»".contains(lastChar) else { continue }
            var lines = result[pageIndex]
            var leading: [PDFColumnTextExtractor.Line] = []
            var index = 0
            while index < lines.count {
                let line = lines[index]
                if ImageDescriptionMarker.hasPlaceholders(in: line.text) {
                    leading.append(line); index += 1; continue
                }
                if PDFFigureDetector.isCaptionStart(line.text) {
                    while index < lines.count {
                        leading.append(lines[index])
                        index += 1
                        if leading.last?.endsParagraph == true { break }
                    }
                    continue
                }
                break
            }
            guard !leading.isEmpty, index < lines.count else { continue }
            lines.removeFirst(index)
            guard let paragraphEnd = lines.firstIndex(where: { $0.endsParagraph }) else { continue }
            lines.insert(contentsOf: leading, at: paragraphEnd + 1)
            result[pageIndex] = lines
        }
        return result
    }

    // MARK: Cross references

    private static let referenceOnlyParenthesis = try! NSRegularExpression(
        pattern: #"\s?\((?:\s*(?:▶|►|→)?\s*(?:vgl\.|siehe|see|cf\.|voir|véase|vedi)?\s*(?:S\.|Seite|Abb\.|Abbildung|Tab\.|Tabelle|Kap\.|Kapitel|Fig\.|Figure|Figura|chap\.|cap\.|pág\.|p\.|pp\.)\s*[\d\.\–\-,\sa-zf]{1,30}[;,]?)+\)"#
    )

    /// Removes parentheses that only hold page/figure/chapter references
    /// ("(S. 403)", "(▶ Abb. 6.8c)", "(vgl. Kap. 3.2)") and stray arrow
    /// symbols — useful on the page, noise when listening.
    static func removeCrossReferences(_ text: String) -> String {
        var result = referenceOnlyParenthesis.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        result = result.replacingOccurrences(of: #"\s?[▶►◀◄→]\s?"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" ([.,;:])"#, with: "$1", options: .regularExpression)
        return result
    }

    // MARK: Line text normalization

    private static let ligatures: [(String, String)] = [
        ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl"), ("\u{FB05}", "st"), ("\u{FB06}", "st"),
    ]

    /// Ligature glyphs ("betroﬀen") and spacing artefacts ("( a)",
    /// "zellulären„Unfalls“") that trip up TTS front ends.
    static func normalizeLineText(_ text: String) -> String {
        var result = text
        for (ligature, replacement) in ligatures where result.contains(ligature) {
            result = result.replacingOccurrences(of: ligature, with: replacement)
        }
        // Letter-spaced words ("M e r k e", "I M P P - H i t s", "1 1"):
        // read letter by letter otherwise.
        let tokens = result.split(separator: " ")
        if tokens.count >= 2, tokens.allSatisfy({ $0.count == 1 }), tokens.count >= 4 || tokens.allSatisfy({ $0.first?.isNumber == true }) {
            result = tokens.joined()
        }
        result = result.replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\p{L})([„“])(\p{L})"#, with: "$1 $2$3", options: .regularExpression)
        return result
    }
}
