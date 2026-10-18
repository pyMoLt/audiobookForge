import Foundation

/// Intelligently clusters atomic subchapters into larger, well-balanced chapters
/// targeting a desired character count, while strictly respecting major thematic
/// boundaries (e.g. Chapter 1 never bleeds into Chapter 2).
enum ChapterRebundler {
    struct ChapterNumber: Equatable {
        let parts: [Int]
        var major: Int? { parts.first }
        var minor: Int? { parts.count > 1 ? parts[1] : nil }
    }

    /// Parses numbers from titles like "1 Grundlagen", "1.2 Pharmakokinetik", "Kapitel 3: ...", "4.1.2 ..."
    static func parseNumber(from title: String) -> ChapterNumber? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:(?:kapitel|chapter)\s+)?(\d{1,3}(?:\.\d{1,3}){0,3})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let numRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        let raw = String(trimmed[numRange])
        let parts = raw.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return ChapterNumber(parts: parts)
    }

    /// Strips leading chapter numbers from a title ("1.2 Pharmakokinetik" -> "Pharmakokinetik")
    static func stripLeadingNumber(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:(?:kapitel|chapter)\s+)?(?:\d{1,3}(?:\.\d{1,3}){0,3})[.:–-]?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range, in: trimmed) else { return trimmed }
        return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Visible character length (excluding invisible image markers)
    static func visibleLength(_ text: String) -> Int {
        ImageDescriptionMarker.stripPlaceholders(from: text).count
    }

    /// Rebundles a list of atomic chapters into larger chapters targeting `targetCharacters`.
    /// Respects major chapter boundaries (e.g. Chapter 1 never bleeds into Chapter 2),
    /// combines subheadings cleanly, and synthesizes informative titles.
    static func rebundle(chapters: [Chapter], targetCharacters: Int) -> [Chapter] {
        guard chapters.count > 1, targetCharacters > 0 else { return chapters }

        var result: [Chapter] = []
        var currentGroup: [Chapter] = []

        func currentGroupLength() -> Int {
            currentGroup.reduce(0) { $0 + visibleLength($1.cleanedText) }
        }

        func flushCurrentGroup() {
            guard !currentGroup.isEmpty else { return }
            if currentGroup.count == 1 {
                var single = currentGroup[0]
                single.order = result.count
                result.append(single)
            } else {
                let merged = combine(group: currentGroup, order: result.count)
                result.append(merged)
            }
            currentGroup.removeAll()
        }

        for chapter in chapters {
            let chapterLen = visibleLength(chapter.cleanedText)

            let currentNum = currentGroup.last.flatMap { parseNumber(from: $0.title) }
            let nextNum = parseNumber(from: chapter.title)

            let isDifferentMajor: Bool = {
                guard let cMaj = currentNum?.major, let nMaj = nextNum?.major else { return false }
                return cMaj != nMaj
            }()

            if isDifferentMajor && !currentGroup.isEmpty {
                flushCurrentGroup()
                currentGroup.append(chapter)
                continue
            }

            if currentGroup.isEmpty {
                currentGroup.append(chapter)
                continue
            }

            let curLen = currentGroupLength()
            let combinedLen = curLen + chapterLen

            if combinedLen <= targetCharacters {
                currentGroup.append(chapter)
            } else {
                // Determine whether adding next chapter brings total closer to target
                let diffWithout = abs(targetCharacters - curLen)
                let diffWith = abs(targetCharacters - combinedLen)
                let maxAllowed = Int(Double(targetCharacters) * 1.35)

                if diffWith < diffWithout && combinedLen <= maxAllowed {
                    currentGroup.append(chapter)
                    flushCurrentGroup()
                } else {
                    flushCurrentGroup()
                    currentGroup.append(chapter)
                }
            }
        }

        flushCurrentGroup()

        for index in result.indices {
            result[index].order = index
        }

        return result
    }

    /// Combines multiple subchapters into a single clean Chapter
    static func combine(group: [Chapter], order: Int) -> Chapter {
        guard let first = group.first else {
            return Chapter(title: "", rawText: "", cleanedText: "", order: order)
        }
        guard group.count > 1 else {
            var ch = first
            ch.order = order
            return ch
        }

        let combinedTitle = synthesizeTitle(from: group)

        var combinedRaw = first.rawText
        var combinedCleaned = first.cleanedText

        for ch in group.dropFirst() {
            let cleanTrimmed = ch.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerPrefix: String
            if cleanTrimmed.hasPrefix(ch.title) {
                headerPrefix = ""
            } else {
                headerPrefix = ch.title + "\n\n"
            }
            combinedRaw += "\n\n" + (headerPrefix.isEmpty ? ch.rawText : ch.title + "\n\n" + ch.rawText)
            combinedCleaned += "\n\n" + headerPrefix + ch.cleanedText
        }

        return Chapter(
            id: first.id,
            title: combinedTitle,
            rawText: combinedRaw,
            cleanedText: combinedCleaned,
            order: order
        )
    }

    /// Synthesizes a readable range title from a group of chapters, e.g.:
    /// "1 Grundlagen der Pharmakologie (bis 1.3 Pharmakodynamik)" or "1.1–1.3 Wegweiser … Pharmakodynamik"
    static func synthesizeTitle(from group: [Chapter]) -> String {
        guard let first = group.first, let last = group.last else { return "" }
        if group.count == 1 { return first.title }

        let firstNum = parseNumber(from: first.title)
        let lastNum = parseNumber(from: last.title)

        if let fNum = firstNum, let lNum = lastNum, fNum.parts != lNum.parts {
            let cFirst = stripLeadingNumber(from: first.title)
            let cLast = stripLeadingNumber(from: last.title)
            let sep = group.count == 2 ? " & " : " … "

            // If first is top-level chapter (e.g. [1]) and last is subsection (e.g. [1, 3])
            if fNum.parts.count == 1 && lNum.parts.count > 1 && fNum.parts[0] == lNum.parts[0] {
                let lStr = lNum.parts.map(String.init).joined(separator: ".")
                return "\(fNum.parts[0]) \(cFirst) (bis \(lStr) \(cLast))".trimmingCharacters(in: .whitespaces)
            }

            let fStr = fNum.parts.map(String.init).joined(separator: ".")
            let lStr = lNum.parts.map(String.init).joined(separator: ".")
            if cFirst == cLast || cLast.isEmpty {
                return "\(fStr)–\(lStr) \(cFirst)".trimmingCharacters(in: .whitespaces)
            } else if cFirst.isEmpty {
                return "\(fStr)–\(lStr) \(cLast)".trimmingCharacters(in: .whitespaces)
            } else {
                return "\(fStr)–\(lStr) \(cFirst)\(sep)\(cLast)".trimmingCharacters(in: .whitespaces)
            }
        }

        if first.title == last.title {
            return first.title
        }
        return "\(first.title) – \(last.title)"
    }
}
