import Foundation

/// Word-level diff between a chapter's original text and its summarized
/// version. Summarization mostly paraphrases rather than verbatim-edits, so
/// this isn't meant to read like a code diff — it highlights which concrete
/// words (names, numbers, technical terms) survived unchanged, which is
/// exactly the signal that matters for "did the summary drop this fact."
enum TextDiffer {
    struct Token: Identifiable {
        let id = UUID()
        let text: String
        let kept: Bool
    }

    struct Result {
        let original: [Token]
        let summary: [Token]
    }

    static func diff(original: String, summary: String) -> Result {
        let originalWords = tokenize(original)
        let summaryWords = tokenize(summary)

        let difference = summaryWords.difference(from: originalWords)

        var removedIndices = Set<Int>()
        var insertedIndices = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedIndices.insert(offset)
            case .insert(let offset, _, _):
                insertedIndices.insert(offset)
            }
        }

        let originalTokens = originalWords.enumerated().map { index, word in
            Token(text: word, kept: !removedIndices.contains(index))
        }
        let summaryTokens = summaryWords.enumerated().map { index, word in
            Token(text: word, kept: !insertedIndices.contains(index))
        }

        return Result(original: originalTokens, summary: summaryTokens)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
