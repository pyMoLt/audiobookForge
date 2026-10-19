import Foundation

/// How box labels ("▶ Merke.", "Definition:") are treated during
/// narration (plan 6.1). The stored chapter text is never modified —
/// the filter only shapes what is read aloud.
enum BoxLabelHandling: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Label-only lines vanish; lines like "▶ Merke. Der Uterus …"
    /// lose the label prefix. Default — the label repeats hundreds of
    /// times in a textbook and adds nothing when heard.
    case remove
    /// Labels stay in place.
    case keep
    /// The label is spoken once per box ("Merke: …"), without the
    /// decorative marker glyph.
    case spoken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .remove: return "Entfernen"
        case .keep: return "Beibehalten"
        case .spoken: return "Vorlesen"
        }
    }
}

/// Removes/reshapes textbook box labels ("▶ Merke.", "▶ Definition.",
/// "Klinischer Fall", …) in narration text. The label catalog lives in
/// `Resources/box_labels_de_en.json` so it can grow without code
/// changes; labels are matched as fixed words (case-insensitive), with
/// optional decorative markers (▶ ▷ ► ▸ •) and an optional trailing
/// "." or ":".
///
/// Rules (plan 6.1):
/// - a line that consists ONLY of the label is removed entirely
///   (`.remove`) or spoken as "Label:" (`.spoken`);
/// - a line starting with the label keeps its text, minus the label
///   prefix;
/// - the word inside a sentence ("Man merke sich …") is never touched.
enum BoxLabelFilter {
    struct CatalogEntry: Codable {
        let text: String
        let languages: [String]?
    }

    struct Catalog: Codable {
        let labels: [CatalogEntry]
    }

    /// Result of a filter pass — counters feed the "Vorbereitung prüfen"
    /// report in the review screen (plan 6.7).
    struct Report: Equatable {
        var removedLabelLines = 0
        var strippedPrefixes = 0
    }

    /// Loaded once; a missing or invalid catalog falls back to the
    /// built-in core labels so narration never breaks.
    private static let catalog: [String] = {
        let fallback = ["Merke", "Definition", "Klinischer Fall", "Synonym", "Praxistipp", "Cave", "Key point", "Note", "Case"]
        guard let url = Bundle.main.url(forResource: "box_labels_de_en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return fallback
        }
        let labels = catalog.labels.map(\.text)
        return labels.isEmpty ? fallback : labels
    }()

    /// Labels sorted by length (longest first) so "Klinischer Fall"
    /// wins over a potential shorter overlap.
    private static let sortedLabels: [String] = catalog.sorted { $0.count > $1.count }

    /// True when `line` consists only of a box label.
    static func isLabelOnlyLine(_ line: String) -> Bool {
        labelOnlyMatch(in: line) != nil
    }

    private static func labelOnlyMatch(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for label in sortedLabels where equalsLabel(trimmed, label) {
            return label
        }
        return nil
    }

    private static func equalsLabel(_ candidate: String, _ label: String) -> Bool {
        var text = candidate
        // Strip a single leading decorative marker.
        for marker in ["▶", "▷", "►", "▸", "•"] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // Strip one trailing "." or ":".
        if text.hasSuffix(".") || text.hasSuffix(":") { text = String(text.dropLast()) }
        return text.caseInsensitiveCompare(label) == .orderedSame
    }

    /// The label prefix of `line` ("▶ Merke. Etwas Text …" → "Merke"),
    /// or nil when the line does not start with a label.
    static func labelPrefix(in line: String) -> (label: String, remainder: String)? {
        for label in sortedLabels {
            for marker in ["▶", "▷", "►", "▸", "•"] {
                if line.hasPrefix(marker) {
                    let rest = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    if let match = matchAtStart(rest, label) { return match }
                }
            }
            if let match = matchAtStart(line, label) { return match }
        }
        return nil
    }

    private static func matchAtStart(_ line: String, _ label: String) -> (label: String, remainder: String)? {
        guard line.count >= label.count,
              line.prefix(label.count).caseInsensitiveCompare(label) == .orderedSame else { return nil }
        var remainder = String(line.dropFirst(label.count))
        // Allow ". ", ": " or a single "."/":" as separator.
        if remainder.hasPrefix(".") || remainder.hasPrefix(":") { remainder = String(remainder.dropFirst()) }
        guard remainder.first?.isWhitespace == true || remainder.isEmpty else { return nil }
        return (label, remainder.trimmingCharacters(in: .whitespaces))
    }

    /// Applies the handling to a whole narration text (line-based).
    /// Returns the shaped text plus counters for the report.
    static func apply(_ text: String, handling: BoxLabelHandling) -> (text: String, report: Report) {
        guard handling != .keep, !text.isEmpty else { return (text, Report()) }
        var report = Report()
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            if let label = labelOnlyMatch(in: line) {
                switch handling {
                case .remove:
                    report.removedLabelLines += 1
                    continue // drop the line entirely
                case .spoken:
                    report.removedLabelLines += 1
                    result.append("\(label):")
                case .keep:
                    result.append(line)
                }
                continue
            }
            if let prefix = labelPrefix(in: line) {
                switch handling {
                case .remove:
                    report.strippedPrefixes += 1
                    result.append(prefix.remainder.isEmpty ? "" : prefix.remainder)
                case .spoken:
                    report.strippedPrefixes += 1
                    result.append("\(prefix.label): \(prefix.remainder)")
                case .keep:
                    result.append(line)
                }
                continue
            }
            result.append(line)
        }
        let joined = result.joined(separator: "\n")
        // Tidy: collapse runs of blank lines left by removed labels.
        let tidied = joined.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (tidied, report)
    }
}
