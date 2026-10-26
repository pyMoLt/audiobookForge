import Foundation

/// Role of a chapter within its document (plan 6.2). The classifier runs
/// once at import; the result is a *suggestion* — the review screen
/// preselects "nicht vorlesen" for TOC/front-matter chapters, and the
/// user can always override it. Nothing is ever silently dropped.
enum ChapterMatterKind: String, Codable, Sendable, Equatable {
    /// Normal body content.
    case body
    /// Title page, preface, author list — read poorly aloud.
    case frontMatter
    /// Table of contents — mostly page numbers and dot fillers.
    case toc
    /// Bibliography, index, register, acknowledgements.
    case backMatter

    var displayName: String {
        switch self {
        case .body: return "Haupttext"
        case .frontMatter: return "Titelei/Vorspann"
        case .toc: return "Inhaltsverzeichnis"
        case .backMatter: return "Anhang/Nachspann"
        }
    }
}

/// Classifies a chapter as body/front-matter/TOC/back-matter from its
/// title and text — deterministically, offline, no model (plan 6.2).
///
/// Signals:
/// - title keywords ("Inhaltsverzeichnis", "Literatur", …);
/// - share of lines ending in a bare page number (… \d{1,4}$) — over
///   40 % is the signature of a table of contents;
/// - dot fillers ("Einleitung …………… 12");
/// - low sentence density (few sentence ends per line).
enum FrontBackMatterClassifier {
    private static let frontMatterTitles: Set<String> = [
        "titelei", "impressum", "vorwort", "autorenverzeichnis", "geleitwort", "vorbemerkung", "danksagung", "widmung",
        "title page", "imprint", "preface", "foreword", "front matter",
        // v4: French, Spanish, Italian.
        "préface", "avant-propos", "remerciements", "dédicace", "prefacio", "prólogo", "agradecimientos", "dedicatoria",
        "prefazione", "premessa", "ringraziamenti", "dedica", "colophon",
    ]
    private static let tocTitles: Set<String> = [
        "inhaltsverzeichnis", "inhalt", "contents", "table of contents", "übersicht",
        "table des matières", "sommaire", "índice", "contenido", "índice general", "indice", "sommario",
    ]
    private static let backMatterTitles: Set<String> = [
        "literatur", "literaturverzeichnis", "sachverzeichnis", "register", "stichwortverzeichnis", "glossar", "index", "abkürzungsverzeichnis", "abbildungsverzeichnis", "tabellenverzeichnis", "anhang",
        "bibliography", "acknowledgements", "appendix",
        "bibliographie", "annexe", "glossaire", "index alphabétique", "bibliografía", "apéndice", "glosario",
        "bibliografia", "appendice", "glossario", "indice analitico",
    ]

    /// Normalizes a title for keyword comparison (lowercase, trimmed,
    /// punctuation removed).
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".:–—-"))
            .trimmingCharacters(in: .whitespaces)
    }

    static func classify(title: String, text: String) -> ChapterMatterKind {
        let normalized = normalizedTitle(title)

        // Exact-ish title hits win: a chapter literally named
        // "Inhaltsverzeichnis" or "Literatur" is what it says.
        if tocTitles.contains(normalized) { return .toc }
        if frontMatterTitles.contains(normalized) { return .frontMatter }
        if backMatterTitles.contains(normalized) { return .backMatter }

        // Geometric TOC signals: many lines ending in a bare number, or
        // dot fillers leading into numbers.
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return .body }
        let numberWithTrailing = lines.filter { line in
            line.range(of: #"\s\d{1,4}$"#, options: .regularExpression) != nil
        }.count
        if Double(numberWithTrailing) / Double(lines.count) > 0.4 { return .toc }
        let dotFillers = lines.filter { $0.contains("……") || $0.range(of: #"\.{4,}\s*\d"#, options: .regularExpression) != nil }.count
        if dotFillers >= 3 { return .toc }

        // Weak signal: extremely low sentence density alone does NOT
        // classify — lists of definitions are legitimate body content.
        return .body
    }

    /// Whether a chapter with this kind should be *suggested* as
    /// "nicht vorlesen" in the review screen.
    static func suggestsSkipping(_ kind: ChapterMatterKind) -> Bool {
        kind == .toc || kind == .frontMatter
    }
}
