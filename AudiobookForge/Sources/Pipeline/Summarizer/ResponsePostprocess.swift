import Foundation

/// Post-processing of raw model responses before they are parsed into
/// chapters (plan 7.5). Everything here is defensive and idempotent: a
/// well-behaved response passes through unchanged.
enum ResponsePostprocess {
    /// Marker that introduces the continuity context block in the user
    /// prompt (see `SummarizerClient`, plan 7.4). If the model echoes the
    /// block back, these lines must not be narrated.
    static let contextMarker = "[Context — already covered, do not summarize again]"

    /// Meta phrases a model tends to open with despite being told not to.
    /// Matched case-insensitively against the FIRST line of the response.
    private static let leadingMetaPhrases = [
        "hier ist",
        "hier hast",
        "hier eine",
        "zusammenfassend",
        "zusammenfassung:",
        "kurzzusammenfassung:",
        "gerne",
        "natürlich",
        "sicher,",
        "in zusammenfassung",
        "in summary",
        "summary:",
        "here is",
        "here's",
        "sure",
        "certainly",
        "of course",
        "absolut,",
    ]

    /// Full cleanup pass over one raw response.
    ///
    /// - `echoedContext`: the continuity context tail that was appended to
    ///   this call's prompt, if any. Lines the model repeated verbatim from
    ///   it are removed so no already-covered text is narrated twice.
    static func clean(_ response: String, echoedContext: String? = nil) -> String {
        var text = stripContextEcho(response, context: echoedContext)
        text = collapseDuplicateHeadings(text)
        text = stripLeadingMetaPhrases(text)
        return text
    }

    /// Removes the response's opening meta line ("Hier ist die
    /// Zusammenfassung …", "Sure, here is …") — but only when content
    /// follows it, so a genuinely short answer is never emptied out.
    static func stripLeadingMetaPhrases(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let firstNewline = trimmed.firstIndex(where: { $0 == "\n" }) else { return text }
        let firstLine = String(trimmed[..<firstNewline])
            .trimmingCharacters(in: .whitespaces)
        let lower = firstLine.lowercased()
        let isMeta = leadingMetaPhrases.contains { lower.hasPrefix($0) }
        guard isMeta else { return text }
        let rest = String(trimmed[trimmed.index(after: firstNewline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? text : rest
    }

    /// Collapses runs of directly consecutive heading lines (with or without
    /// a blank line between them) into the LAST heading of the run — a
    /// heading followed immediately by another heading marks an empty
    /// section, and the second heading is the one the content belongs to.
    static func collapseDuplicateHeadings(_ text: String) -> String {
        var result: [String] = []
        var pendingHeadings: [String] = []

        for line in text.components(separatedBy: "\n") {
            if isHeadingLine(line) {
                pendingHeadings.append(line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // While a heading run is open, blank lines only separate it
                // from whatever comes next — drop them so the surviving
                // heading sits next to its content. Otherwise keep the
                // paragraph structure (collapsing doubled blanks).
                if pendingHeadings.isEmpty, result.last?.trimmingCharacters(in: .whitespaces).isEmpty != true {
                    result.append(line)
                }
                continue
            }
            if let last = pendingHeadings.last { result.append(last) }
            pendingHeadings = []
            result.append(line)
        }
        if let last = pendingHeadings.last { result.append(last) }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("##") || trimmed.hasPrefix("# ") || trimmed.hasPrefix("**")
    }

    /// Removes the continuity context block from a response, for the ways a
    /// model can echo it: the marker line itself, whole lines repeated
    /// verbatim from the context tail, and echoed sentences fused into the
    /// start of a line that continues with new content.
    static func stripContextEcho(_ text: String, context: String?) -> String {
        var lines = text.components(separatedBy: "\n").filter { line in
            line.trimmingCharacters(in: .whitespaces) != contextMarker
        }
        guard let context, !context.isEmpty else {
            return lines.joined(separator: "\n")
        }
        // Sentences of the context tail that the model repeated. Split the
        // tail into sentences to catch partial echoes (the model rarely
        // repeats all ~600 characters at once).
        let echoedSentences = context
            .components(separatedBy: ".")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 20 }

        lines = lines.map { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            for sentence in echoedSentences where trimmed.hasPrefix(sentence) {
                if trimmed == sentence || trimmed == sentence + "." {
                    return nil // pure echo — drop the whole line
                }
                // Echo fused with new content — keep only the new part.
                // A line that merely shares the sentence's start but
                // continues differently ("... vor" → "... vorm Haus")
                // is NOT an echo and stays untouched.
                let rest = String(trimmed.dropFirst(sentence.count))
                    .trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(".") {
                    let remainder = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                    return remainder.isEmpty ? nil : remainder
                }
            }
            return line
        }.compactMap { $0 }
        return lines.joined(separator: "\n")
    }
}
