import Foundation

/// Detects short lines that recur at the top/bottom of many pages (running
/// titles, journal names, page numbers) and strips them. Page numbers and
/// similar counters are normalized before comparison so "Page 7" and
/// "Page 8" are recognized as the same recurring pattern.
enum HeaderFooterStripper {
    static func strip(pageTexts: [String]) -> [String] {
        guard pageTexts.count >= 4 else { return pageTexts }

        var firstLineCounts: [String: Int] = [:]
        var lastLineCounts: [String: Int] = [:]
        var perPageFirstLast: [(first: String?, last: String?)] = []

        for text in pageTexts {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let first = lines.first
            let last = lines.last
            perPageFirstLast.append((first, last))
            if let first, isCandidateHeaderFooterLine(first) {
                firstLineCounts[normalize(first), default: 0] += 1
            }
            if let last, isCandidateHeaderFooterLine(last) {
                lastLineCounts[normalize(last), default: 0] += 1
            }
        }

        let pageCount = pageTexts.count
        let threshold = max(3, Int(Double(pageCount) * 0.35))

        let recurringFirst = Set(firstLineCounts.filter { $0.value >= threshold }.keys)
        let recurringLast = Set(lastLineCounts.filter { $0.value >= threshold }.keys)

        guard !recurringFirst.isEmpty || !recurringLast.isEmpty else { return pageTexts }

        return pageTexts.map { text in
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let first = lines.first, isCandidateHeaderFooterLine(first), recurringFirst.contains(normalize(first)) {
                lines.removeFirst()
            }
            if let last = lines.last, isCandidateHeaderFooterLine(last), recurringLast.contains(normalize(last)) {
                lines.removeLast()
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Header/footer lines are short by nature; long lines are real body text
    /// even if they happen to repeat (e.g. a repeated section heading).
    private static func isCandidateHeaderFooterLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 90
    }

    private static func normalize(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var result = ""
        result.reserveCapacity(trimmed.count)
        var lastWasDigit = false
        for char in trimmed {
            if char.isNumber {
                if !lastWasDigit {
                    result.append("#")
                }
                lastWasDigit = true
            } else {
                result.append(char)
                lastWasDigit = false
            }
        }
        return result.lowercased()
    }
}
