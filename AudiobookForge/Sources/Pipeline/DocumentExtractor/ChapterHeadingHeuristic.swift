import Foundation

/// Fallback chapter detection for documents without an embedded outline
/// (mainly PDFs). Looks for short, heading-shaped lines such as "Chapter 3",
/// "Kapitel IV", "3. Introduction", or an all-caps short line on its own.
enum ChapterHeadingHeuristic {
    private static let patterns: [String] = [
        // v4: also French, Spanish, Italian ("Chapitre", "Capítulo", "Capitolo").
        #"^\s*(chapter|kapitel|chapitre|cap[ií]tulo|capitolo)\s+([ivxlcdm]+|\d+|[a-zà-ú]+)\b.*$"#,
        #"^\s*(\d{1,3})[\.\)]\s+[A-ZÄÖÜ].{0,80}$"#,
    ]

    private static let compiledPatterns: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    static func split(fullText: String) -> [ExtractedChapter] {
        let lines = fullText.components(separatedBy: "\n")
        var headingIndices: [Int] = []

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.count <= 90 else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let isHeading = compiledPatterns.contains { pattern in
                pattern.firstMatch(in: line, options: [], range: range) != nil
            } || isAllCapsHeadingLike(line)
            if isHeading {
                headingIndices.append(index)
            }
        }

        // Require a reasonable amount of separation between detected headings
        // and at least a couple of matches, otherwise this is probably noise
        // (e.g. a document with lots of short, capitalized labels).
        let filteredIndices = dedupeCloseIndices(headingIndices, minGap: 3)
        guard filteredIndices.count >= 2 else {
            return [ExtractedChapter(title: "Gesamtes Dokument", text: fullText)]
        }

        var chapters: [ExtractedChapter] = []
        for (chapterNumber, startIndex) in filteredIndices.enumerated() {
            let endIndex = chapterNumber + 1 < filteredIndices.count ? filteredIndices[chapterNumber + 1] : lines.count
            let title = lines[startIndex].trimmingCharacters(in: .whitespaces)
            let bodyLines = lines[(startIndex + 1)..<endIndex]
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            chapters.append(ExtractedChapter(title: title.isEmpty ? "Kapitel \(chapterNumber + 1)" : title, text: body))
        }

        if filteredIndices.first != 0 {
            let preambleLines = lines[0..<filteredIndices[0]]
            let preamble = preambleLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if preamble.count > 200 {
                chapters.insert(ExtractedChapter(title: "Einleitung", text: preamble), at: 0)
            }
        }

        return chapters.isEmpty ? [ExtractedChapter(title: "Gesamtes Dokument", text: fullText)] : chapters
    }

    /// Detects an all-caps section heading such as "INTRODUCTION" or
    /// "COMPARISON OF p53 GENETIC ALTERATIONS AND" — the latter still needs
    /// to match despite its lowercase "p", a stylized gene-name convention
    /// ("p53", "mRNA", …) that's common even inside otherwise-uppercase
    /// biology/medicine headings. A plain regex character class can't
    /// express "almost all uppercase, with the odd stylized exception," so
    /// this uses a ratio instead: at least 85% of the line's letters must be
    /// uppercase. This was previously a regex run case-insensitively
    /// alongside the other two patterns — which silently made its
    /// upper/lowercase distinction meaningless and caused it to match
    /// nearly every ordinary column-wrapped body-text line in a paper with
    /// no PDF outline (each such line is short enough and made of letters,
    /// digits and spaces), fragmenting the document into dozens of bogus
    /// one-paragraph "chapters" titled after a mid-sentence fragment.
    private static func isAllCapsHeadingLike(_ line: String) -> Bool {
        guard line.count >= 5, line.count <= 70 else { return false }
        guard let first = line.first, first.isLetter || first.isNumber else { return false }
        let letters = line.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        let uppercaseCount = letters.filter(\.isUppercase).count
        return Double(uppercaseCount) / Double(letters.count) >= 0.85
    }

    private static func dedupeCloseIndices(_ indices: [Int], minGap: Int) -> [Int] {
        var result: [Int] = []
        for index in indices {
            if let last = result.last, index - last < minGap {
                continue
            }
            result.append(index)
        }
        return result
    }

    // MARK: - Even split fallback

    /// Derives a short, recognizable chapter title from the opening words of
    /// its text — e.g. "In my younger and more …" — so auto-generated
    /// chapter titles give the reader a clue about where they are, unlike a
    /// bare "Teil 1".
    static func titleFromFirstWords(_ text: String, maxWords: Int = 6) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ", maxSplits: maxWords + 1, omittingEmptySubsequences: true)
        guard !words.isEmpty else { return "Ohne Titel" }
        let selected = words.prefix(maxWords)
        var title = selected.joined(separator: " ")
        if words.count > maxWords { title += " …" }
        // Strip trailing punctuation that looks odd as a title-end (comma,
        // semicolon) but keep sentence-final marks (period, !, ?).
        while title.hasSuffix(",") || title.hasSuffix(";") {
            title = String(title.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    /// Splits a continuous text into roughly equal-sized chapters at paragraph
    /// boundaries. Used when neither an embedded outline nor heading patterns
    /// produced any chapter structure — the last resort before handing the
    /// user a single monolithic "Gesamtes Dokument" chapter.
    static func splitEvenly(fullText: String, targetCharacters: Int = 15000) -> [ExtractedChapter] {
        let paragraphs = fullText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard paragraphs.count > 1 else {
            return [ExtractedChapter(title: titleFromFirstWords(fullText), text: fullText)]
        }

        let totalChars = paragraphs.reduce(0) { $0 + $1.count }
        let numParts = max(1, Int(round(Double(totalChars) / Double(targetCharacters))))

        guard numParts > 1 else {
            return [ExtractedChapter(title: titleFromFirstWords(fullText), text: fullText)]
        }

        let targetPerPart = totalChars / numParts
        var chapters: [ExtractedChapter] = []
        var currentParagraphs: [String] = []
        var currentSize = 0
        var partNumber = 1

        for paragraph in paragraphs {
            currentParagraphs.append(paragraph)
            currentSize += paragraph.count

            if currentSize >= targetPerPart && partNumber < numParts && !currentParagraphs.isEmpty {
                let text = currentParagraphs.joined(separator: "\n\n")
                chapters.append(ExtractedChapter(
                    title: titleFromFirstWords(text),
                    text: text
                ))
                currentParagraphs = []
                currentSize = 0
                partNumber += 1
            }
        }

        if !currentParagraphs.isEmpty {
            let text = currentParagraphs.joined(separator: "\n\n")
            chapters.append(ExtractedChapter(
                title: titleFromFirstWords(text),
                text: text
            ))
        }

        return chapters.isEmpty ? [ExtractedChapter(title: titleFromFirstWords(fullText), text: fullText)] : chapters
    }
}
