import Foundation
import NaturalLanguage

/// Native (NaturalLanguage-based) sentence splitting, shared by any TTS
/// engine that needs to synthesize sentence-by-sentence to get per-sentence
/// timing data.
enum SentenceSplitter {
    static func split(_ text: String) -> [String] {
        // NLTokenizer treats ANY literal newline as a forced sentence
        // boundary, even mid-sentence — confirmed empirically: a hard-wrapped
        // line like "...by trying\nto make it too true..." gets split into
        // two "sentences" right at the wrap, not at the real end of the
        // sentence. Both extracted PDFs (line-wrap reconstruction inserts a
        // bare "\n" between wrapped lines of the same paragraph) and EPUBs
        // (Gutenberg's HTML frequently keeps the source's ~70-character hard
        // line wraps as literal newlines inside a single <p>) can carry this.
        // Each such fragment becomes its own TTS segment downstream, and a
        // segment boundary means an audible pause — mid-sentence. Collapsing
        // all whitespace (including embedded newlines) to single spaces
        // before tokenizing lets the tokenizer split purely on real
        // sentence-ending punctuation instead.
        let normalized = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = normalized
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let sentence = normalized[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return mergeFalseBreaks(sentences)
    }

    /// NLTokenizer also ends a "sentence" after common abbreviations,
    /// initials and German ordinal dates — verified: "Am 3. | Oktober…",
    /// "Mr. | Smith…", "Prof. | Dr. Meier…". With one TTS segment per
    /// sentence that fragment would be spoken as its own sentence (falling
    /// intonation, pause). Re-joins a fragment with the next one when it
    /// ends in such a token.
    static func mergeFalseBreaks(_ sentences: [String]) -> [String] {
        var result: [String] = []
        for sentence in sentences {
            if let previous = result.last, endsWithFalseBreak(previous, next: sentence) {
                result[result.count - 1] = previous + " " + sentence
            } else {
                result.append(sentence)
            }
        }
        return result
    }

    private static let abbreviations: Set<String> = [
        // English
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "sr.", "jr.", "vs.", "no.", "fig.", "vol.", "ch.", "pp.", "approx.", "e.g.", "i.e.", "cf.", "inc.", "ltd.", "co.", "mt.", "gen.", "col.", "capt.", "rev.",
        // German
        "hr.", "fr.", "nr.", "abb.", "kap.", "bd.", "ca.", "bzw.", "vgl.", "z.b.", "u.a.", "d.h.", "s.", "jh.", "jhd.", "geb.", "gest.", "evtl.", "ggf.", "inkl.", "zzgl.", "usw.", "sog.", "tab.", "str.", "dipl.", "ing.", "mio.", "mrd.", "rd.", "bspw.",
        // Months (both languages)
        "jan.", "feb.", "mär.", "apr.", "jun.", "jul.", "aug.", "sep.", "sept.", "okt.", "oct.", "nov.", "dez.", "dec.",
    ]

    private static let monthNames: Set<String> = [
        "januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember",
        "january", "february", "march", "may", "june", "july", "october", "december",
        "jänner",
    ]

    private static func endsWithFalseBreak(_ sentence: String, next: String) -> Bool {
        guard let lastToken = sentence.split(separator: " ").last.map({ String($0).lowercased() }) else { return false }
        let nextFirst = next.split(separator: " ").first.map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if abbreviations.contains(lastToken) { return true }
        // Initials: "J." in "J. R. R. Tolkien"
        if lastToken.count == 2, lastToken.first?.isLetter == true, lastToken.last == "." , sentence.count > 2 { return true }
        // German ordinal date / ordinal before a month or a lower-case word: "Am 3. Oktober", "der 2. Weltkrieg" is excluded (capitalized noun) on purpose.
        if lastToken.range(of: #"^\d{1,2}\.$"#, options: .regularExpression) != nil {
            if monthNames.contains(nextFirst) { return true }
            if let first = next.first, first.isLowercase { return true }
        }
        return false
    }
}
