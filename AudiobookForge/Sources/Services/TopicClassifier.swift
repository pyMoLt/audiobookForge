import Foundation

/// Automatic, offline topic classification for the sidebar (plan 9.5).
/// Deterministic keyword scoring — no LLM involved.
///
/// Score = Σ keyword weight × capped hit density (hits per 10 000 chars).
/// A book lands in the topic with the highest score if the score clears
/// the threshold AND leads the runner-up by ≥ 20 % — otherwise it stays
/// "Sonstiges". Confidence (0–1) is stored alongside; a manual override
/// (`topicOverride`) always wins and is never touched again.
enum TopicClassifier {
    struct Topic: Equatable, Sendable, Identifiable, Hashable {
        let id: String
        let displayName: String
        let systemImage: String

        static let medicine = Topic(id: "medicine", displayName: L("Medizin & Gesundheit"), systemImage: "cross.case")
        static let science = Topic(id: "science", displayName: L("Naturwissenschaft & Technik"), systemImage: "atom")
        static let literature = Topic(id: "literature", displayName: L("Literatur & Belletristik"), systemImage: "books.vertical")
        static let history = Topic(id: "history", displayName: L("Geschichte & Gesellschaft"), systemImage: "building.columns")
        static let economy = Topic(id: "economy", displayName: L("Wirtschaft & Recht"), systemImage: "briefcase")
        static let other = Topic(id: "other", displayName: L("Sonstiges"), systemImage: "folder")

        /// Fixed catalog (user decision, plan 9.5) — order = sidebar order.
        static let catalog: [Topic] = [.medicine, .science, .literature, .history, .economy, .other]
    }

    struct KeywordList: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            let keyword: String
            let weight: Int
        }
        let entries: [Entry]
    }

    /// Score threshold above which a topic assignment happens at all.
    static let scoreThreshold = 4.0
    /// Minimum relative lead over the runner-up (0.2 = 20 %).
    static let leadFraction = 0.2
    /// Hit density cap per keyword (hits per 10 000 characters).
    static let densityCap = 6.0

    struct Result: Equatable, Sendable {
        let topic: Topic
        let confidence: Double
    }

    /// Classifies a book from its metadata + a text sample.
    /// `textSample` should be ~20 000 chars from the longest chapters
    /// (callers strip image description markers).
    static func classify(title: String, author: String, documentType: DocumentType, textSample: String, languageCode: String?) -> Result {
        let lists = keywordLists(languageCode: languageCode)
        let scores = scores(title: title, documentType: documentType, textSample: textSample, lists: lists)

        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= scoreThreshold else {
            return Result(topic: .other, confidence: 0)
        }
        let runnerUp = ranked.count > 1 ? ranked[1].value : 0
        let requiredLead = runnerUp * (1 + leadFraction)
        guard best.value >= requiredLead || runnerUp == 0 else {
            return Result(topic: .other, confidence: 0.2)
        }

        let margin = runnerUp > 0 ? (best.value - runnerUp) / best.value : 1.0
        let confidence = min(1.0, margin * 0.5 + min(best.value / 20.0, 1.0) * 0.5)
        return Result(topic: best.key, confidence: confidence)
    }

    /// Per-topic scores (exposed for tests).
    static func scores(title: String, documentType: DocumentType, textSample: String, lists: [Topic: KeywordList]) -> [Topic: Double] {
        let sample = normalize(textSample)
        let titleLower = normalize(title)
        let per10k = 10_000.0 / Double(max(sample.count, 1))

        var scores: [Topic: Double] = [:]
        for (topic, list) in lists where topic != .other {
            var score = 0.0
            for entry in list.entries {
                let keyword = normalize(entry.keyword)
                guard !keyword.isEmpty else { continue }
                var hits = Double(countOccurrences(of: keyword, in: sample)) * per10k
                // Title hits count double — the title carries the genre.
                if titleLower.contains(keyword) { hits += 2 }
                score += Double(entry.weight) * min(hits, densityCap)
            }
            if score > 0 { scores[topic] = score }
        }
        // Document-type priors: a "book" leans literature, a paper leans
        // science — weak, only relevant on ties.
        switch documentType {
        case .paper: scores[.science, default: 0] += 1.0
        case .book: scores[.literature, default: 0] += 1.0
        default: break
        }
        return scores
    }

    /// Loads the keyword lists for a language (falls back to the other
    /// language's list merged in).
    static func keywordLists(languageCode: String?) -> [Topic: KeywordList] {
        // Merge every language (v4.1: + French, Spanish, Italian): books
        // quote terms from other languages; each list carries its own weights.
        let lists = ["de", "en", "fr", "es", "it"].compactMap { loadList(resource: "topic_keywords_\($0)") }
        var result: [Topic: KeywordList] = [.other: KeywordList(entries: [])]
        for topic in Topic.catalog where topic != .other {
            result[topic] = KeywordList(entries: lists.flatMap { $0.entries(for: topic) ?? [] })
        }
        _ = languageCode
        return result
    }

    private static func loadList(resource: String) -> KeywordListData? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeywordListData.self, from: data)
    }

    /// The JSON resource format: { "medicine": [{keyword, weight} …], … }
    struct KeywordListData: Codable {
        let medicine: [KeywordList.Entry]?
        let science: [KeywordList.Entry]?
        let literature: [KeywordList.Entry]?
        let history: [KeywordList.Entry]?
        let economy: [KeywordList.Entry]?

        init(medicine: [KeywordList.Entry]? = nil, science: [KeywordList.Entry]? = nil, literature: [KeywordList.Entry]? = nil, history: [KeywordList.Entry]? = nil, economy: [KeywordList.Entry]? = nil) {
            self.medicine = medicine
            self.science = science
            self.literature = literature
            self.history = history
            self.economy = economy
        }

        func entries(for topic: Topic) -> [KeywordList.Entry]? {
            switch topic.id {
            case Topic.medicine.id: return medicine
            case Topic.science.id: return science
            case Topic.literature.id: return literature
            case Topic.history.id: return history
            case Topic.economy.id: return economy
            default: return []
            }
        }
    }

    // MARK: - Text helpers

    static func normalize(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Substring hit count (word-boundary lenient — cheap and deterministic).
    static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
            if count > 500 { break } // hard cap for pathological inputs
        }
        return count
    }
}
