import Foundation

/// List bullets and heading numbers in narration text (plan 6.4).
/// Works on narration only — stored chapter text keeps its markers.
///
/// - Bullet lines ("▪ Pathologie der Ovarien") become proper spoken
///   sentences: bullet stripped, first letter capitalized, trailing
///   period added when the line has no sentence punctuation. (The short
///   list pause itself is the pause engine's job, plan 8.4.)
/// - Stray bullets mid-text (not at line start) are removed.
/// - Numbered headings ("1.2 Titel") lose their spoken number unless
///   `speakHeadingNumbers` is on; chapter titles are cleaned of the
///   numbering at import.
enum ListNumberingFilter {
    /// Bullet characters seen in extracted textbook PDFs.
    private static let bullets: Set<Character> = ["•", "▪", "●", "■", "□", "▸", "▶", "◦", "‣"]

    struct Report: Equatable {
        var listItems = 0
        var strayBulletsRemoved = 0
        var headingNumbersStripped = 0
    }

    /// True for a heading-like line: starts with 1–4 part numbering
    /// followed by an uppercase word ("1.2 Therapie", "12 Einführung").
    static func isNumberedHeadingLine(_ line: String) -> Bool {
        line.range(of: #"^\d{1,3}(\.\d{1,3}){0,3}\s+[A-ZÄÖÜ]"#, options: .regularExpression) != nil
    }

    /// The numbering prefix of a heading/title ("1.2 Therapie" → "1.2 ").
    static func numberingPrefix(in line: String) -> String? {
        guard let range = line.range(of: #"^\d{1,3}(\.\d{1,3}){0,3}\s+"#, options: .regularExpression) else { return nil }
        return String(line[range])
    }

    /// Strips a leading numbering from a chapter title ("1.2 Therapie" →
    /// "Therapie"). Non-destructive for titles without numbering.
    static func cleanedTitle(_ title: String) -> String {
        guard let prefix = numberingPrefix(in: title) else { return title }
        return String(title.dropFirst(prefix.count))
    }

    /// Applies list/heading normalization to a narration text.
    static func apply(_ text: String, speakHeadingNumbers: Bool) -> (text: String, report: Report) {
        var report = Report()
        var outputLines: [String] = []

        for line in text.components(separatedBy: "\n") {
            var shaped = line

            // 1) Heading numbering.
            if !speakHeadingNumbers, let prefix = numberingPrefix(in: shaped.trimmingCharacters(in: .whitespaces)) {
                shaped = String(shaped.trimmingCharacters(in: .whitespaces).dropFirst(prefix.count))
                report.headingNumbersStripped += 1
            }

            // 2) Bullet list items at line start → spoken sentence.
            let trimmed = shaped.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, bullets.contains(first) {
                var item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let firstLetter = item.first {
                    item = String(firstLetter.uppercased()) + item.dropFirst()
                }
                if let last = item.last, !".!?".contains(last) {
                    item += "."
                }
                shaped = item
                report.listItems += 1
            } else {
                // 3) Bullets NOT at line start are always stray.
                let withoutStray = shaped.filter { !bullets.contains($0) }
                report.strayBulletsRemoved += shaped.count - withoutStray.count
                shaped = String(withoutStray)
            }

            outputLines.append(shaped)
        }

        return (outputLines.joined(separator: "\n"), report)
    }
}
