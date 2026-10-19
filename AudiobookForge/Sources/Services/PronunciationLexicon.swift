import Foundation

/// Engine-independent pronunciation lexicon (plan 6.6): applied to
/// narration text only, never to the stored chapter text. Layers:
///
/// 1. exact word replacements (word boundaries, case-sensitive) from
///    `Resources/lexicon_de_med.json` / `lexicon_en_med.json` plus the
///    user lexicon (`lexicon_user.json` in Application Support);
/// 2. anatomical abbreviations with context ("M. levator ani" →
///    "Musculus levator ani", but "M. Müller" stays);
/// 3. units and dose forms ("mg/dl", "mmHg", "µg", "IE", "%", "°C");
/// 4. Greek letters ("α-" → "Alpha-");
/// 5. roman numerals after "Typ"/"Typus"/"Grad"/"Stadium" ("Typ II" →
///    "Typ zwei").
enum PronunciationLexicon {
    struct ExactRule: Codable {
        let from: String
        let to: String
    }

    struct Catalog: Codable {
        let exact: [ExactRule]?
    }

    private static let deAbbreviations: [String: String] = [
        "M.": "Musculus", "Mm.": "Musculi",
        "N.": "Nervus", "Nn.": "Nervi",
        "A.": "Arteria", "Aa.": "Arteriae",
        "V.": "Vena", "Vv.": "Venae",
        "Lig.": "Ligamentum", "Ligg.": "Ligamenta",
        "Lnn.": "Lymphonodi", "Ln.": "Lymphonodus",
        "R.": "Ramus", "Rr.": "Rami",
        "T.": "Tuba", "Ggl.": "Ganglion",
    ]

    private static let greekLetters: [String: String] = [
        "α": "Alpha", "β": "Beta", "γ": "Gamma", "δ": "Delta", "ε": "Epsilon",
        "λ": "Lambda", "µ": "mikro", "μ": "mikro", "π": "Pi", "σ": "Sigma", "ω": "Omega",
    ]

    private static let romanNumerals: [String: String] = [
        "I": "eins", "II": "zwei", "III": "drei", "IV": "vier", "V": "fünf",
        "VI": "sechs", "VII": "sieben", "VIII": "acht", "IX": "neun", "X": "zehn",
    ]

    /// Loaded once per language; an invalid or missing file just means
    /// "no exact rules" — the programmatic rules still apply.
    static func catalog(languageCode: String) -> [ExactRule] {
        let isEnglish = languageCode.lowercased().hasPrefix("en")
        let resourceName = isEnglish ? "lexicon_en_med" : "lexicon_de_med"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.exact ?? []
    }

    static func userLexiconURL() -> URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("lexicon_user.json")
    }

    /// The user lexicon merges over the built-in catalog (plan 6.6:
    /// "Fehlbetonungen füllen das Lexikon"). Never created implicitly.
    static func userRules() -> [ExactRule] {
        guard let data = try? Data(contentsOf: userLexiconURL()),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.exact ?? []
    }

    /// Applies all layers to one narration text. Deterministic and
    /// idempotent: `apply(apply(x)) == apply(x)`.
    static func apply(_ text: String, languageCode: String) -> String {
        var result = text
        // 5) Roman numerals in type/stage contexts.
        result = replaceRomanNumerals(result)
        // 1) Exact rules FIRST — user rules win over built-ins, and they
        // must run before the abbreviation pass ("V. a." would otherwise
        // become "Vena a.").
        let rules = userRules() + catalog(languageCode: languageCode)
        for rule in rules {
            result = replaceExact(result, from: rule.from, to: rule.to)
        }
        // 2) Anatomical abbreviations (context-checked).
        result = replaceAnatomicalAbbreviations(result, languageCode: languageCode)
        // 3) Units.
        result = replaceUnits(result)
        // 4) Greek letters.
        result = replaceGreek(result)
        return result
    }

    // MARK: - Layers

    private static func escape(_ literal: String) -> String {
        NSRegularExpression.escapedPattern(for: literal)
    }

    /// "M. levator ani" → "Musculus levator ani"; "M. Müller" (proper
    /// name, capitalized follower) and "Der M. wuchs" (no follower) stay.
    private static func replaceAnatomicalAbbreviations(_ text: String, languageCode: String) -> String {
        guard !languageCode.lowercased().hasPrefix("en") else { return text }
        var result = text
        for (abbreviation, expansion) in deAbbreviations.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "(?<![\\p{L}])\(escape(abbreviation)) (?=[\\p{Ll}])"
            result = result.replacingOccurrences(of: pattern, with: "\(expansion) ", options: .regularExpression)
        }
        return result
    }

    /// Word-boundary replacement, case-sensitive on the "from" term.
    private static func replaceExact(_ text: String, from: String, to: String) -> String {
        let pattern = "(?<![\\p{L}])\(escape(from))(?![\\p{L}])"
        return text.replacingOccurrences(of: pattern, with: to, options: .regularExpression)
    }

    private static let unitPatterns: [(pattern: String, replacement: String)] = [
        (#"(\d)\s*mg/dl"#, "$1 Milligramm pro Deziliter"),
        (#"(\d)\s*mg/dL"#, "$1 Milligramm pro Deziliter"),
        (#"(\d)\s*g/dl"#, "$1 Gramm pro Deziliter"),
        (#"(\d)\s*mmHg"#, "$1 Millimeter Quecksilber"),
        (#"(\d)\s*mmHg\b"#, "$1 Millimeter Quecksilber"),
        (#"(\d)\s*µg\b"#, "$1 Mikrogramm"),
        (#"(\d)\s*°C"#, "$1 Grad Celsius"),
        (#"(\d)\s*%"#, "$1 Prozent"),
        (#"(?<![\p{L}])(IE)(?![\p{L}])"#, "Internationale Einheiten"),
    ]

    private static func replaceUnits(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in unitPatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    private static func replaceGreek(_ text: String) -> String {
        var result = text
        for (letter, name) in greekLetters {
            result = result.replacingOccurrences(of: letter, with: name)
        }
        return result
    }

    private static func replaceRomanNumerals(_ text: String) -> String {
        var result = text
        for (numeral, word) in romanNumerals {
            let pattern = "(?i)(Typ|Typus|Grad|Stadium|Klasse|Gruppe) \(numeral)(?![\\p{L}])"
            result = result.replacingOccurrences(of: pattern, with: "$1 \(word)", options: .regularExpression)
        }
        return result
    }
}
