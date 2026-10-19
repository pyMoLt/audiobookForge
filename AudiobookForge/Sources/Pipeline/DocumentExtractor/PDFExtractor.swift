import Foundation
import PDFKit
import AppKit

struct PDFExtractor: DocumentExtractor {
    var settings: AppSettings = AppSettings()

    func extract(from url: URL) async throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentExtractionError.unreadableDocument(url.lastPathComponent)
        }
        guard document.pageCount > 0 else {
            throw DocumentExtractionError.emptyDocument
        }

        return try await Task.detached(priority: .userInitiated) {
            let (pageLines, pageTexts, usedOCR, figureCount) = try extractPageTexts(document: document)
            return try finishExtraction(document: document, pageLines: pageLines, pageTexts: pageTexts, usedOCR: usedOCR, detectedImageCount: figureCount, url: url)
        }.value
    }

    private var cleanerOptions: PDFTextbookCleaner.Options {
        var options = PDFTextbookCleaner.Options()
        options.removeFigureLabels = settings.removeFigureLabelText
        options.keepCaptions = settings.keepFigureCaptions
        options.insertFigurePlaceholders = true
        options.thresholds = PDFFigureDetector.Thresholds(
            minimumPixelSize: settings.minimumImageDimensionForVisionPass,
            minimumAreaFraction: settings.minimumImageAreaPercent / 100,
            minimumKilobytes: settings.minimumImageKilobytes,
            maximumAspectRatio: settings.maximumImageAspectRatio,
            detectVectorFigures: settings.detectVectorFigures
        )
        return options
    }

    /// Per page: reading-order lines → figure/label/caption cleanup with
    /// position-exact figure placeholders → footnotes; then across pages:
    /// running heads, page numbers and thumb tabs. Placeholders are always
    /// inserted (cheap, geometry only); whether a figure gets described or
    /// dropped is decided per run, so it can change without re-importing.
    private func extractPageTexts(document: PDFDocument) throws -> (lines: [[PDFColumnTextExtractor.Line]], texts: [String], usedOCR: Bool, figures: Int) {
        var pageLines: [[PDFColumnTextExtractor.Line]] = []
        var pageBounds: [CGRect] = []
        var figureCount = 0
        let options = cleanerOptions
        for pageIndex in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: pageIndex) else {
                    pageLines.append([])
                    pageBounds.append(.zero)
                    return
                }
                let bounds = page.bounds(for: .mediaBox)
                pageBounds.append(bounds)
                let ordered = PDFColumnTextExtractor.orderedLines(on: page)
                let cleaned = PDFTextbookCleaner.process(page: page, pageIndex: pageIndex, lines: ordered, options: options)
                figureCount += cleaned.figureCount
                var kept = PDFFrontMatterFilter.filterFootnoteLines(cleaned.lines, pageBounds: bounds)
                if settings.defaultDocumentType == .paper { kept = kept.filter { !Self.isTableRow($0.text) } }
                pageLines.append(kept)
            }
        }
        pageLines = PDFTextbookCleaner.removePageFurniture(pageLines: pageLines, pageBounds: pageBounds)
        pageLines = Self.dropRepeatedFigures(pageLines)
        pageLines = PDFTextbookCleaner.moveFiguresBehindPageBreakSentences(pageLines)
        var pageTexts = pageLines.map { PDFColumnTextExtractor.joinedText($0) }

        var usedOCR = false
        if PDFOCRFallback.needsOCR(pageTexts: pageTexts.map(ImageDescriptionMarker.stripPlaceholders)) {
            usedOCR = true
            pageLines = Array(repeating: [], count: document.pageCount)
            for pageIndex in 0..<document.pageCount {
                autoreleasepool {
                    guard let page = document.page(at: pageIndex) else { return }
                    pageTexts[pageIndex] = PDFOCRFallback.recognizeText(on: page)
                }
            }
        }

        return (pageLines, pageTexts, usedOCR, figureCount)
    }

    /// Result-table rows ("BERTBASE 84.4 88.4 86.7") are noise when read aloud.
    static func isTableRow(_ text: String) -> Bool {
        guard !ImageDescriptionMarker.hasPlaceholders(in: text) else { return false }
        let tokens = text.split(separator: " ")
        guard tokens.count >= 4 else { return false }
        let numeric = tokens.filter { token in
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "%±()[],;:*†"))
            return !t.isEmpty && t.allSatisfy { $0.isNumber || ".-–+/".contains($0) }
        }.count
        return Double(numeric) / Double(tokens.count) >= 0.6
    }

    /// A figure at the same position on many pages is a logo/watermark,
    /// not content.
    static func dropRepeatedFigures(_ pageLines: [[PDFColumnTextExtractor.Line]]) -> [[PDFColumnTextExtractor.Line]] {
        let pageCount = pageLines.count
        guard pageCount > 3 else { return pageLines }
        func positionKey(_ line: PDFColumnTextExtractor.Line) -> String? {
            guard let ref = ImageDescriptionMarker.figures(in: line.text).first?.ref, let rect = ref.cgRect else { return nil }
            return "\(Int(rect.minX / 4)),\(Int(rect.minY / 4)),\(Int(rect.width / 4)),\(Int(rect.height / 4))"
        }
        var counts: [String: Int] = [:]
        for lines in pageLines {
            Set(lines.compactMap(positionKey)).forEach { counts[$0, default: 0] += 1 }
        }
        let threshold = max(3, Int(Double(pageCount) * 0.3))
        return pageLines.map { lines in
            lines.filter { line in
                guard let key = positionKey(line) else { return true }
                return counts[key, default: 0] < threshold
            }
        }
    }

    private func finishExtraction(document: PDFDocument, pageLines: [[PDFColumnTextExtractor.Line]], pageTexts: [String], usedOCR: Bool, detectedImageCount: Int = 0, url: URL) throws -> ExtractedDocument {
        let strippedPageTexts = HeaderFooterStripper.strip(pageTexts: pageTexts)

        let (title, author) = detectTitleAndAuthor(document: document, firstPageLines: pageLines.first ?? [], firstPageBounds: document.page(at: 0)?.bounds(for: .mediaBox) ?? .zero, firstPageText: strippedPageTexts.first ?? "", fileURL: url)

        // Title/author detection needs the untrimmed front matter (the
        // title itself lives there); narration doesn't — drop everything
        // up to "Abstract" (letterhead, author names, affiliations) only
        // now, for the chapter-text path.
        let narrationPageLines = usedOCR ? pageLines : PDFFrontMatterFilter.trimFrontMatter(pageLines: pageLines)
        let narrationPageTexts = usedOCR ? strippedPageTexts : HeaderFooterStripper.strip(pageTexts: narrationPageLines.map { PDFColumnTextExtractor.joinedText($0) })

        let chapters = detectChapters(document: document, pageTexts: narrationPageTexts, pageLines: usedOCR ? nil : narrationPageLines)
        guard !chapters.isEmpty, chapters.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DocumentExtractionError.emptyDocument
        }

        let coverData = renderCoverImage(document: document)

        return ExtractedDocument(
            suggestedTitle: title,
            suggestedAuthor: author,
            chapters: chapters,
            coverImageData: coverData,
            usedOCR: usedOCR,
            detectedImageCount: detectedImageCount
        )
    }

    // MARK: - Title / author

    private func detectTitleAndAuthor(document: PDFDocument, firstPageLines: [PDFColumnTextExtractor.Line], firstPageBounds: CGRect, firstPageText: String, fileURL: URL) -> (String, String) {
        let attributes = document.documentAttributes ?? [:]
        let metadataTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataAuthor = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var title = isUsableTitle(metadataTitle) ? metadataTitle! : ""
        let author = metadataAuthor?.isEmpty == false ? metadataAuthor! : ""

        if title.isEmpty, let geometricTitle = titleFromLargestLineOnPage(firstPageLines, pageBounds: firstPageBounds) {
            title = geometricTitle
        }

        // Plain PDFs (one font size): the topmost block, if it reads like a
        // heading. The joined page text merges it with the first paragraph,
        // so the text fallback below can't see it on its own.
        // (Unfiltered blocks: the cleaned list drops a heading at the very
        // top of the page as a running header.)
        if title.isEmpty, let page = document.page(at: 0),
           let top = PDFColumnTextExtractor.orderedLines(on: page).max(by: { $0.bounds.midY < $1.bounds.midY }) {
            let text = top.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 3, text.count <= 100, Self.looksLikeTitle(text), !text.hasSuffix("."),
               !PDFFrontMatterFilter.isBoilerplate(text) {
                title = text
            }
        }

        if title.isEmpty {
            let candidateLines = firstPageText
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Prefer a heading-like line (short, no sentence ending) over the
            // first long line — that was a body paragraph in plain PDFs.
            let headingLike = candidateLines.prefix(6).first { line in
                line.count >= 3 && line.count <= 100 && !line.hasSuffix(".") && !line.hasSuffix(",") && !line.hasSuffix(";")
            }
            if let line = headingLike ?? candidateLines.first(where: { $0.count > 8 && $0.count < 150 }) {
                title = line
            }
        }

        if title.isEmpty {
            title = fileURL.deletingPathExtension().lastPathComponent
        }

        return (title, author)
    }

    static func looksLikeTitle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 160 && !(trimmed.count > 60 && (trimmed.hasSuffix(".") || trimmed.hasSuffix(",")))
    }

    /// PDF metadata titles are sometimes garbage (a boilerplate permission
    /// notice, a LaTeX temp filename, "Untitled") rather than the real
    /// title — reject the obviously-wrong ones so a better heuristic gets a
    /// chance instead.
    private func isUsableTitle(_ candidate: String?) -> Bool {
        guard let candidate, !candidate.isEmpty, candidate.count < 300 else { return false }
        let lowered = candidate.lowercased()
        let rejectPhrases = ["untitled", "microsoft word", "permission", "copyright", "creative commons", ".tex", ".doc"]
        // A file name is not a title ("Report-final.pdf", "notes.txt").
        let fileSuffixes = [".pdf", ".txt", ".rtf", ".md", ".html", ".odt", ".pages"]
        return !rejectPhrases.contains { lowered.contains($0) } && !fileSuffixes.contains { lowered.hasSuffix($0) }
    }

    /// Finds the title by looking for the tallest normal (horizontal, not
    /// rotated) line of text in the upper portion of the page, rather than
    /// assuming the first extracted line is the title. This is geometric
    /// (line bounding boxes we already compute for column detection) rather
    /// than font-attribute based, which matters because it naturally
    /// excludes things like arXiv's vertical identifier banner along the
    /// page edge: a 90°-rotated string's axis-aligned bounding box is tall
    /// and narrow, the opposite shape of a real horizontal title line.
    private func titleFromLargestLineOnPage(_ lines: [PDFColumnTextExtractor.Line], pageBounds: CGRect) -> String? {
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        let topThreshold = pageBounds.minY + pageBounds.height * 0.55
        // Repository letterheads ("NIH Public Access" and similar) sit right
        // at the very top edge of the page, often in a bigger/bolder font
        // than the real title below them — exclude that band outright
        // rather than just picking the tallest line on the whole upper half.
        let excludedTopBand = pageBounds.maxY - pageBounds.height * 0.08
        let leftMargin = pageBounds.minX + pageBounds.width * 0.08
        let rightMargin = pageBounds.maxX - pageBounds.width * 0.08

        let candidates = lines.filter { line in
            line.bounds.midY >= topThreshold
                && line.bounds.midY <= excludedTopBand
                && line.bounds.width > line.bounds.height // horizontal, not a rotated vertical banner
                && line.bounds.midX >= leftMargin && line.bounds.midX <= rightMargin
                && line.text.trimmingCharacters(in: .whitespaces).count > 8
                && !PDFFrontMatterFilter.isBoilerplate(line.text)
                // "Lines" can be whole wrapped paragraphs — a title is short
                // and doesn't read like a sentence.
                && Self.looksLikeTitle(line.text)
        }
        guard let tallest = candidates.max(by: { $0.bounds.height < $1.bounds.height }) else { return nil }
        // Only a line that really stands out typographically is a title: in
        // a uniformly set page every line is "tallest", and merging same-
        // height neighbours then returned a whole body paragraph.
        let heights = lines.map(\.bounds.height).sorted()
        let median = heights.isEmpty ? 0 : heights[heights.count / 2]
        guard tallest.bounds.height > median * 1.15 else { return nil }

        // The title often wraps onto a second line of very similar height,
        // directly below the first — merge those together, but only lines
        // close by, so an unrelated same-sized heading elsewhere on the
        // page doesn't get pulled in.
        let maxGap = tallest.bounds.height * 2.5
        let sameBlock = candidates
            .filter { abs($0.bounds.height - tallest.bounds.height) < 1.5 && abs($0.bounds.midY - tallest.bounds.midY) < maxGap }
            .sorted { $0.bounds.midY > $1.bounds.midY }

        let candidate = sameBlock.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (candidate.count > 8 && candidate.count < 250) ? candidate : nil
    }

    // MARK: - Chapters

    private func detectChapters(document: PDFDocument, pageTexts: [String], pageLines: [[PDFColumnTextExtractor.Line]]?) -> [ExtractedChapter] {
        if let pageLines, let outlineChapters = chaptersFromOutline(document: document, pageLines: pageLines), !outlineChapters.isEmpty {
            return outlineChapters
        }

        // PDFKit can omit an outline when re-writing a PDF. Prominent title-
        // case headings still carry useful structure even when the textual
        // fallback only recognizes numbered or all-caps headings.
        if settings.defaultDocumentType == .paper, let pageLines,
           let paper = PDFNumberedHeadingDetector.chapters(pageLines: pageLines, targetAverageCharacters: 2500, relaxed: true), paper.count >= 2 {
            return paper
        }
        if let pageLines, let numbered = PDFNumberedHeadingDetector.chapters(pageLines: pageLines), numbered.count >= 2 {
            return numbered
        }

        if let pageLines, let visualChapters = chaptersFromProminentHeadings(pageLines: pageLines), visualChapters.count >= 2 {
            return visualChapters
        }

        // Papers: bold same-size section headings ("2 Related Work",
        // "4.1 GLUE") plus unnumbered References/Acknowledgements.
        if let pageLines, let paper = PDFNumberedHeadingDetector.chapters(pageLines: pageLines, targetAverageCharacters: 2500, relaxed: true), paper.count >= 2 {
            return paper
        }

        let fullText = pageTexts.joined(separator: "\n\n")
        return ChapterHeadingHeuristic.split(fullText: fullText)
    }

    private func chaptersFromProminentHeadings(pageLines: [[PDFColumnTextExtractor.Line]]) -> [ExtractedChapter]? {
        let globalLines = pageLines.enumerated().flatMap { pageIndex, lines in
            lines.map { GlobalLine(pageIndex: pageIndex, line: $0) }
        }
        guard globalLines.count >= 4 else { return nil }

        var headings: [(title: String, globalIndex: Int)] = []
        var offset = 0
        for lines in pageLines {
            // Typical body-text line height: the median of real text lines,
            // not the smallest line on the page — in a textbook the smallest
            // line is a figure label, which made almost every line count as
            // a "prominent heading".
            let heights = lines.filter { $0.text.count >= 30 }.map(\.bounds.height).filter { $0 > 0 }.sorted()
            guard !heights.isEmpty, case let bodyHeight = heights[heights.count / 2], bodyHeight > 0 else {
                offset += lines.count
                continue
            }
            for (index, line) in lines.enumerated() {
                let title = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.count >= 4, title.count <= 100,
                      line.bounds.height >= bodyHeight * 1.35,
                      !PDFFrontMatterFilter.isBoilerplate(title),
                      title.first?.isUppercase == true else { continue }
                headings.append((title, offset + index))
            }
            offset += lines.count
        }
        guard headings.count >= 2 else { return nil }

        var chapters: [ExtractedChapter] = []
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].globalIndex : globalLines.count
            guard end > heading.globalIndex else { continue }
            let body = PDFColumnTextExtractor.joinedText(globalLines[heading.globalIndex..<end].map(\.line))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= 40 else { continue }
            chapters.append(ExtractedChapter(title: heading.title, text: body))
        }
        return chapters.count >= 2 ? chapters : nil
    }

    /// A single flattened, page-tagged line — lets us locate an outline
    /// destination with line-level (not just page-level) precision, so two
    /// chapters that both start on the same physical page (very common in
    /// densely-set two-column papers) don't both get handed the whole page.
    private struct GlobalLine {
        let pageIndex: Int
        let line: PDFColumnTextExtractor.Line
    }

    private func chaptersFromOutline(document: PDFDocument, pageLines: [[PDFColumnTextExtractor.Line]]) -> [ExtractedChapter]? {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return nil }

        struct Entry {
            let title: String
            let pageIndex: Int
            let point: CGPoint
        }

        var entries: [Entry] = []
        func walk(_ outline: PDFOutline) {
            for i in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: i) else { continue }
                if let destination = child.destination, let destPage = destination.page, let label = child.label {
                    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !PDFFrontMatterFilter.isJunkOutlineLabel(trimmedLabel) {
                        let pageIndex = document.index(for: destPage)
                        entries.append(Entry(title: trimmedLabel, pageIndex: pageIndex, point: destination.point))
                    }
                }
                // Recurse into nested bookmarks too (a "Part"/"Chapter" tree),
                // flattened into one chapter list — over-fragmentation from
                // deep nesting is cleaned up afterwards by the minimum-length
                // merge pass, which is more robust than guessing which
                // outline depth is "the right one" up front.
                walk(child)
            }
        }
        walk(root)
        guard !entries.isEmpty else { return nil }

        let globalLines: [GlobalLine] = pageLines.enumerated().flatMap { pageIndex, lines in
            lines.map { GlobalLine(pageIndex: pageIndex, line: $0) }
        }
        guard !globalLines.isEmpty else { return nil }

        // Resolve each outline entry to the closest matching line, globally
        // ordered — this is what lets two entries share a page correctly.
        var resolved: [(title: String, globalIndex: Int)] = []
        for entry in entries {
            guard let globalIndex = closestGlobalLineIndex(pageIndex: entry.pageIndex, point: entry.point, label: entry.title, globalLines: globalLines) else { continue }
            resolved.append((entry.title, globalIndex))
        }
        guard !resolved.isEmpty else { return nil }
        resolved.sort { $0.globalIndex < $1.globalIndex }

        var chapters: [ExtractedChapter] = []
        for (index, entry) in resolved.enumerated() {
            let endIndex = index + 1 < resolved.count ? resolved[index + 1].globalIndex : globalLines.count
            guard endIndex > entry.globalIndex else { continue }
            let text = PDFColumnTextExtractor.joinedText(globalLines[entry.globalIndex..<endIndex].map(\.line)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            chapters.append(ExtractedChapter(title: entry.title.isEmpty ? "Kapitel \(index + 1)" : entry.title, text: text))
        }

        return chapters
    }

    private func closestGlobalLineIndex(pageIndex: Int, point: CGPoint, label: String, globalLines: [GlobalLine]) -> Int? {
        let candidates = globalLines.enumerated().filter { $0.element.pageIndex == pageIndex }
        guard !candidates.isEmpty else {
            // Destination page had no extracted lines (e.g. a blank or
            // image-only page) — fall back to the first line of the next
            // page with content.
            return globalLines.firstIndex { $0.pageIndex > pageIndex }
        }

        // Plan 6.5: Text comparison has priority over Y position. If a line
        // matches the outline label (exact or prefix), that is the heading line.
        if let textMatch = matchByLabelText(label, in: candidates) {
            return textMatch
        }

        // Many PDF producers write outline destinations without a real
        // point (a "Fit"/"FitH" destination rather than "XYZ"), which
        // PDFKit then reports as a huge sentinel-like value — useless for
        // Y-matching, and actively harmful: every entry on the same page
        // would resolve to the same line, silently collapsing all but the
        // last one.
        if !isUsablePoint(point) {
            return candidates.first?.offset
        }

        // Prefer the first line at or below the destination point (reading
        // order proceeds downward); fall back to the nearest line overall
        // if the destination points above everything on the page.
        if let atOrBelow = candidates.first(where: { $0.element.line.bounds.midY <= point.y + 2 }) {
            return atOrBelow.offset
        }
        let nearest = candidates.min { abs($0.element.line.bounds.midY - point.y) < abs($1.element.line.bounds.midY - point.y) }
        return nearest?.offset
    }

    private func isUsablePoint(_ point: CGPoint) -> Bool {
        point.y.isFinite && abs(point.y) < 100_000
    }

    private func matchByLabelText(_ label: String, in candidates: [(offset: Int, element: GlobalLine)]) -> Int? {
        let normalizedLabel = normalizeForMatching(label)
        guard !normalizedLabel.isEmpty else { return nil }

        if let exact = candidates.first(where: { normalizeForMatching($0.element.line.text) == normalizedLabel }) {
            return exact.offset
        }

        let prefixLength = min(15, normalizedLabel.count)
        guard prefixLength >= 6 else { return nil } // too short a label to prefix-match safely
        let labelPrefix = String(normalizedLabel.prefix(prefixLength))
        if let prefixMatch = candidates.first(where: { normalizeForMatching($0.element.line.text).hasPrefix(labelPrefix) }) {
            return prefixMatch.offset
        }

        return nil
    }

    private func normalizeForMatching(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func renderCoverImage(document: PDFDocument) -> Data? {
        autoreleasepool {
            guard let page = document.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            let image = NSImage(size: bounds.size)
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                NSColor.white.setFill()
                ctx.fill(bounds)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
    }
}
