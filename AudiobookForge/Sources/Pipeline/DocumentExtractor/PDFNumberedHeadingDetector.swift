import Foundation
import PDFKit

/// Chapter structure for PDFs without an outline that use numbered
/// headings ("6 Zellteilung …", "6.4 Wachstum, Zelltod", "6.4.2 Zelltod") —
/// the norm for textbooks and lecture scripts.
///
/// Robustness rules, all learned on a real 714-page textbook:
/// - numbering must strictly increase through the book, which rejects
///   cross-references, numbered list items and stray figure labels;
/// - a candidate must look like a heading: not a sentence, no trailing
///   page number, at least body-text height and set apart (own paragraph
///   or a larger font);
/// - pages that are mostly "text … 123" lines (table of contents, index)
///   are not narrated at all;
/// - the heading depth used for chapters is the deepest level whose
///   chapters average at least ~5 000 characters (≈ 6 minutes of audio),
///   so a book becomes navigable sections rather than 600 snippets or
///   20 two-hour chapters.
enum PDFNumberedHeadingDetector {
    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,2}(?:\.\d{1,2}){0,3})\.?\s*(\p{Lu}[^\n]{1,100})$"#
    )

    struct Candidate {
        let number: [Int]
        let title: String
        let globalIndex: Int
    }

    /// Back-matter headings that appear unnumbered in papers.
    private static let backMatterKeywords: Set<String> = ["references", "bibliography", "literatur", "literaturverzeichnis", "acknowledgements", "acknowledgments", "acknowledgement", "danksagung", "appendix", "supplementary material", "conflict of interest", "funding", "author contributions"]

    /// `relaxed` is for papers: headings are usually set in the body size
    /// (just bold), so the size test is dropped in favour of "stands alone,
    /// short, mostly letters", and unnumbered back-matter headings
    /// (References …) become boundaries.
    static func chapters(pageLines: [[PDFColumnTextExtractor.Line]], targetAverageCharacters: Int = 3500, relaxed: Bool = false) -> [ExtractedChapter]? {
        let listingPages = Set(pageLines.indices.filter { isListingPage(pageLines[$0]) })
        let bodyHeight = typicalBodyHeight(pageLines)

        var globalLines: [PDFColumnTextExtractor.Line] = []
        var candidates: [Candidate] = []
        var lastNumber: [Int] = []
        var skipThrough = -1
        for (pageIndex, lines) in pageLines.enumerated() where !listingPages.contains(pageIndex) {
            for (index, line) in lines.enumerated() {
                if globalLines.count <= skipThrough {
                    // Continuation line of a multi-line heading: part of
                    // the title, not of the body.
                    globalLines.append(PDFColumnTextExtractor.Line(text: "", bounds: .zero, endsParagraph: false))
                    continue
                }
                defer { globalLines.append(line) }
                // Chapter number on its own line above a large title
                // ("1" / "Grundlagen der Pharmakologie").
                let loneNumber = line.text.trimmingCharacters(in: .whitespaces)
                if loneNumber.range(of: #"^\d{1,2}$"#, options: .regularExpression) != nil,
                   index + 1 < lines.count,
                   case let titleLine = lines[index + 1],
                   bodyHeight > 0, titleLine.bounds.height >= bodyHeight * 1.5,
                   parse(titleLine.text) == nil,
                   titleLine.text.first?.isUppercase == true,
                   let chapterNumber = Int(loneNumber),
                   [chapterNumber].lexicographicallyPrecedes(lastNumber) == false, [chapterNumber] != lastNumber {
                    var fullTitle = titleLine.text.trimmingCharacters(in: .whitespaces)
                    var continuation = index + 2
                    while continuation < lines.count, continuation <= index + 3,
                          abs(lines[continuation].bounds.height - titleLine.bounds.height) <= 0.6 {
                        fullTitle += " " + lines[continuation].text.trimmingCharacters(in: .whitespaces)
                        continuation += 1
                    }
                    lastNumber = [chapterNumber]
                    skipThrough = globalLines.count + (continuation - index - 1)
                    candidates.append(Candidate(number: [chapterNumber], title: "\(chapterNumber) \(fullTitle)", globalIndex: globalLines.count))
                    continue
                }
                if relaxed, !lastNumber.isEmpty,
                   backMatterKeywords.contains(line.text.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".:"))),
                   index == 0 || lines[index - 1].endsParagraph {
                    let next = [lastNumber[0] + 1]
                    lastNumber = next
                    candidates.append(Candidate(number: next, title: line.text.trimmingCharacters(in: .whitespaces), globalIndex: globalLines.count))
                    continue
                }
                guard let (number, title) = parse(line.text) else { continue }
                // Numbered list ("5. Kaliumkanalöffner" / "6. Endothelin…"):
                // a neighbouring line with a number of the same depth and
                // the same size means list items, not headings.
                let isListItem = [index - 1, index + 1].contains { neighbour in
                    guard lines.indices.contains(neighbour), let other = parse(lines[neighbour].text) else { return false }
                    return other.number.count == number.count && abs(lines[neighbour].bounds.height - line.bounds.height) <= 0.6
                }
                if isListItem { continue }
                // Headings are set noticeably larger than body text (real
                // textbook: 12.8–18 pt vs. ~10 pt). Without a measurable
                // body size fall back to "stands alone as a paragraph".
                if relaxed {
                    let previousEndsParagraph = index == 0 || lines[index - 1].endsParagraph
                    guard line.endsParagraph, previousEndsParagraph, bodyHeight == 0 || line.bounds.height >= bodyHeight * 0.92 else { continue }
                    let letters = title.filter(\.isLetter).count
                    guard Double(letters) >= Double(title.count) * 0.75, title.count >= 3 else { continue }
                    guard !title.hasSuffix(","), title.split(separator: " ").count <= 10 else { continue }
                } else if bodyHeight > 0 {
                    guard line.bounds.height >= bodyHeight * 1.15 else { continue }
                } else {
                    let previousEndsParagraph = index == 0 || lines[index - 1].endsParagraph
                    guard line.endsParagraph && previousEndsParagraph else { continue }
                }
                guard number.lexicographicallyPrecedes(lastNumber) == false, number != lastNumber else { continue }
                // Allow skipping at most a few numbers at the top level —
                // "6" jumping to "61" is a misread, not a chapter.
                if let top = number.first, let lastTop = lastNumber.first, top > lastTop + 3 { continue }
                lastNumber = number

                // Multi-line heading: following lines in the same size
                // that aren't numbered themselves belong to the title.
                var fullTitle = title
                var continuation = index + 1
                var isListingEntry = false
                while !relaxed, continuation < lines.count, continuation <= index + 2,
                      abs(lines[continuation].bounds.height - line.bounds.height) <= 0.6,
                      parse(lines[continuation].text) == nil,
                      lines[continuation].text.count <= 90 {
                    let next = lines[continuation].text.trimmingCharacters(in: .whitespaces)
                    // "8 Binde- und Stütz-" / "gewebe 147": an overview
                    // entry with page number, not the heading itself.
                    if next.range(of: #"\s\d{1,4}$"#, options: .regularExpression) != nil { isListingEntry = true; break }
                    fullTitle = PDFColumnTextExtractor.dehyphenatedJoin(fullTitle, next: next).map { $0 + next } ?? fullTitle + " " + next
                    continuation += 1
                }
                if isListingEntry { lastNumber = previousNumber(candidates); continue }
                skipThrough = globalLines.count + (continuation - index - 1)
                candidates.append(Candidate(number: number, title: "\(number.map(String.init).joined(separator: ".")) \(fullTitle)", globalIndex: globalLines.count))
            }
        }
        guard candidates.count >= 3 else { return nil }

        let totalCharacters = globalLines.reduce(0) { $0 + $1.text.count }
        // Deepest level whose chapters still average the target size; for
        // a short document where no level reaches it, the coarsest level
        // that still yields at least two chapters.
        let usableDepths = (1...4).filter { depth in candidates.filter { $0.number.count <= depth }.count >= 2 }
        guard let coarsest = usableDepths.first else { return nil }
        let chosenDepth = usableDepths.last { depth in
            totalCharacters / candidates.filter { $0.number.count <= depth }.count >= targetAverageCharacters
        } ?? coarsest
        let boundaries = candidates.filter { $0.number.count <= chosenDepth }
        guard boundaries.count >= 2 else { return nil }

        var chapters: [ExtractedChapter] = []
        var mergedIntro: (title: String, text: String)?
        if let first = boundaries.first, first.globalIndex > 0 {
            let preamble = PDFColumnTextExtractor.joinedText(Array(globalLines[0..<first.globalIndex])).trimmingCharacters(in: .whitespacesAndNewlines)
            if ImageDescriptionMarker.stripPlaceholders(from: preamble).count > 200 {
                chapters.append(ExtractedChapter(title: "Vorspann", text: preamble))
            }
        }
        for (index, heading) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1].globalIndex : globalLines.count
            let body = end > heading.globalIndex + 1
                ? PDFColumnTextExtractor.joinedText(Array(globalLines[(heading.globalIndex + 1)..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            // A short chapter intro ("5 Zellorganellen …" + one paragraph
            // before "5.1") is merged *forward* into its first subsection
            // under a combined title. Merging it backwards (what a plain
            // minimum-length rule does) would bury chapter 5's title and
            // intro at the end of section 4.3.
            if let next = boundaries[safe: index + 1], next.number.starts(with: heading.number),
               ImageDescriptionMarker.stripPlaceholders(from: body).count < minimumIntroCharacters {
                let carried = mergedIntro.map { ($0.title, $0.text + "\n\n" + heading.title + "\n\n" + body) } ?? (heading.title, body)
                mergedIntro = (carried.0, carried.1)
                continue
            }
            if let intro = mergedIntro {
                chapters.append(ExtractedChapter(title: "\(intro.title) – \(heading.title)", text: [intro.text, heading.title, body].filter { !$0.isEmpty }.joined(separator: "\n\n")))
                mergedIntro = nil
            } else if !body.isEmpty {
                chapters.append(ExtractedChapter(title: heading.title, text: body))
            }
        }
        if let intro = mergedIntro, !intro.text.isEmpty {
            chapters.append(ExtractedChapter(title: intro.title, text: intro.text))
        }
        return chapters.count >= 2 ? chapters : nil
    }

    static let minimumIntroCharacters = 1500

    private static func previousNumber(_ candidates: [Candidate]) -> [Int] {
        candidates.last?.number ?? []
    }

    static func parse(_ text: String) -> (number: [Int], title: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 110,
              let match = headingRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let numberRange = Range(match.range(at: 1), in: trimmed),
              let titleRange = Range(match.range(at: 2), in: trimmed) else { return nil }
        let title = String(trimmed[titleRange]).trimmingCharacters(in: .whitespaces)
        // Sentences and listing entries are not headings.
        // A trailing comma is allowed: multi-line headings break there
        // ("6.3 Zelldifferenzierung, Zellumsatz," / "Stammzellen").
        if title.hasSuffix(".") || title.hasSuffix(":") { return nil }
        if title.range(of: #"(\.{2,}|\s)\d{1,4}$"#, options: .regularExpression) != nil { return nil }
        if title.split(separator: " ").count > 14 { return nil }
        let number = trimmed[numberRange].split(separator: ".").compactMap { Int($0) }
        guard !number.isEmpty, number.first! > 0 else { return nil }
        return (number, title)
    }

    /// Table of contents / index page: most lines end in a page number.
    static func isListingPage(_ lines: [PDFColumnTextExtractor.Line]) -> Bool {
        let textLines = lines.filter { $0.bounds != .zero && $0.text.count >= 4 }
        guard textLines.count >= 5 else { return false }
        let endingInNumber = textLines.filter { $0.text.range(of: #"\d{1,4}(\s*[f]{1,2}\.?)?$"#, options: .regularExpression) != nil }.count
        let dotLeaders = textLines.filter { $0.text.range(of: #"(\.\s?){4,}"#, options: .regularExpression) != nil }.count
        return Double(endingInNumber) / Double(textLines.count) >= 0.3 || dotLeaders >= 3
    }

    private static func typicalBodyHeight(_ pageLines: [[PDFColumnTextExtractor.Line]]) -> CGFloat {
        let heights = pageLines.flatMap { $0 }.filter { $0.text.count >= 40 && $0.bounds.height > 0 }.map(\.bounds.height).sorted()
        return heights.isEmpty ? 0 : heights[heights.count / 2]
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
