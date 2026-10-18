import Foundation

/// Where a figure sits in the source, plus what the extractor knew about
/// it. Encoded into an invisible, app-internal placeholder in the chapter
/// text — the LLM never sees these; they're resolved by the app into a
/// plain "Abbildung: …" paragraph (or removed) before any text is
/// summarized or narrated.
struct FigureReference: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case pdf, epub }

    var source: Source
    /// PDF: 0-based page index and figure rect in page coordinates.
    var page: Int?
    var rect: [Double]?
    /// EPUB: image path relative to the archive root.
    var path: String?
    var kind: String?
    var caption: String?
    var altText: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var encodedBytes: Int?

    var cgRect: CGRect? {
        guard let rect, rect.count == 4 else { return nil }
        return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    }

    /// Stable identity independent of caption wording, for caching.
    var key: String {
        switch source {
        case .pdf: return "pdf:\(page ?? -1):\((rect ?? []).map { String(Int($0.rounded())) }.joined(separator: ","))"
        case .epub: return "epub:\(path ?? "")"
        }
    }
}

/// How long a stored description is: the full one for straight narration,
/// or the shorter one handed to the summarizer.
enum FigureDescriptionLength: String, Codable, Sendable {
    case full
    case short
}

/// What to do with one figure when resolving a text.
enum FigureResolution {
    case describe(String, FigureDescriptionLength)
    /// Leave the placeholder/block exactly as it is (e.g. failed call —
    /// retried on the next run).
    case keep
    case remove
}

enum ImageDescriptionMarker {
    private static let separator = "\u{2063}"
    private static let openTag = "\u{2063}IMGDESC-OPEN\u{2063}"
    private static let closeTag = "\u{2063}IMGDESC-CLOSE\u{2063}"
    private static let placeholderOpen = "\u{2063}IMG-PH:"
    private static let placeholderClose = "\u{2063}"

    private struct BlockMeta: Codable {
        var ref: FigureReference
        var length: FigureDescriptionLength
    }

    // MARK: Placeholders (figure not described yet)

    static func placeholder(for reference: FigureReference) -> String {
        "\(placeholderOpen)\(encode(reference))\(placeholderClose)"
    }

    static func hasPlaceholders(in text: String) -> Bool {
        text.contains(placeholderOpen)
    }

    /// All figures in reading order — pending placeholders and already
    /// described blocks — with the length of an existing description.
    static func figures(in text: String) -> [(ref: FigureReference, existing: FigureDescriptionLength?)] {
        var result: [(FigureReference, FigureDescriptionLength?)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let nextPlaceholder = text.range(of: placeholderOpen, range: index..<text.endIndex)
            let nextBlock = text.range(of: openTag, range: index..<text.endIndex)
            guard let next = [nextPlaceholder, nextBlock].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { break }
            if next == nextPlaceholder {
                guard let close = text.range(of: placeholderClose, range: next.upperBound..<text.endIndex) else { break }
                if let ref = decode(FigureReference.self, String(text[next.upperBound..<close.lowerBound])) {
                    result.append((ref, nil))
                }
                index = close.upperBound
            } else {
                guard let close = text.range(of: closeTag, range: next.upperBound..<text.endIndex) else { break }
                let body = text[next.upperBound..<close.lowerBound]
                if let sep = body.range(of: separator), let meta = decode(BlockMeta.self, String(body[body.startIndex..<sep.lowerBound])) {
                    result.append((meta.ref, meta.length))
                }
                index = close.upperBound
            }
        }
        return result
    }

    /// Replaces every placeholder and every described block: with a new
    /// described block when `provider` returns text for that figure,
    /// otherwise removes it. Legacy (pre-reference) placeholders and blocks
    /// without metadata are kept as they are unless `dropLegacy`.
    static func resolveFigures(
        in text: String,
        dropLegacy: Bool = false,
        provider: (FigureReference, FigureDescriptionLength?) -> FigureResolution
    ) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let nextPlaceholder = text.range(of: placeholderOpen, range: index..<text.endIndex)
            let nextBlock = text.range(of: openTag, range: index..<text.endIndex)
            guard let next = [nextPlaceholder, nextBlock].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { break }
            result += text[index..<next.lowerBound]
            let isPlaceholder = next == nextPlaceholder
            guard let close = text.range(of: isPlaceholder ? placeholderClose : closeTag, range: next.upperBound..<text.endIndex) else {
                result += text[next.lowerBound...]
                return tidy(result)
            }
            let body = String(text[next.upperBound..<close.lowerBound])
            var ref: FigureReference?
            var existing: FigureDescriptionLength?
            if isPlaceholder {
                ref = decode(FigureReference.self, body)
            } else if let sep = body.range(of: separator), let meta = decode(BlockMeta.self, String(body[body.startIndex..<sep.lowerBound])) {
                ref = meta.ref
                existing = meta.length
            }
            if let ref {
                switch provider(ref, existing) {
                case .describe(let description, let length):
                    result += block(description, ref: ref, length: length)
                case .keep:
                    result += text[next.lowerBound..<close.upperBound]
                case .remove:
                    break
                }
            } else if !dropLegacy {
                result += text[next.lowerBound..<close.upperBound]
            }
            index = close.upperBound
        }
        result += text[index...]
        return tidy(result)
    }

    /// Existing description text of a described block for `ref`, if any.
    static func existingDescription(for ref: FigureReference, in text: String) -> String? {
        var index = text.startIndex
        while let open = text.range(of: openTag, range: index..<text.endIndex),
              let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex) {
            let body = text[open.upperBound..<close.lowerBound]
            if let sep = body.range(of: separator),
               let meta = decode(BlockMeta.self, String(body[body.startIndex..<sep.lowerBound])),
               meta.ref.key == ref.key {
                return String(body[sep.upperBound...])
            }
            index = close.upperBound
        }
        return nil
    }

    private static func block(_ description: String, ref: FigureReference, length: FigureDescriptionLength) -> String {
        "\n\n\(openTag)\(encode(BlockMeta(ref: ref, length: length)))\(separator)\(description)\(closeTag)\n\n"
    }

    /// Legacy helper kept for tests/old data: a block without metadata.
    static func wrap(_ description: String) -> String {
        "\n\n\(openTag)\(description)\(closeTag)"
    }

    // MARK: Final text for narration / summarization / display

    /// Described blocks become their plain description paragraph;
    /// placeholders disappear.
    static func unwrap(_ text: String) -> String {
        resolveBlocks(stripPlaceholders(from: text), keepContent: true)
    }

    /// Both described blocks and placeholders disappear.
    static func stripBlocks(from text: String) -> String {
        resolveBlocks(stripPlaceholders(from: text), keepContent: false)
    }

    static func stripPlaceholders(from text: String) -> String {
        guard text.contains(placeholderOpen) else { return text }
        var result = ""
        var index = text.startIndex
        while let open = text.range(of: placeholderOpen, range: index..<text.endIndex) {
            result += text[index..<open.lowerBound]
            guard let close = text.range(of: placeholderClose, range: open.upperBound..<text.endIndex) else {
                index = text.endIndex
                break
            }
            index = close.upperBound
        }
        result += text[index...]
        return tidy(result)
    }

    /// For the review/diff UI: placeholders shown as a short visible tag.
    static func displayText(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while let open = text.range(of: placeholderOpen, range: index..<text.endIndex),
              let close = text.range(of: placeholderClose, range: open.upperBound..<text.endIndex) {
            result += text[index..<open.lowerBound]
            let ref = decode(FigureReference.self, String(text[open.upperBound..<close.lowerBound]))
            let where_ = ref?.page.map { " (Seite \($0 + 1))" } ?? ""
            result += "[Abbildung\(where_)]"
            index = close.upperBound
        }
        result += text[index...]
        return resolveBlocks(result, keepContent: true)
    }

    private static func resolveBlocks(_ text: String, keepContent: Bool) -> String {
        guard text.contains(openTag) else { return text }
        var result = ""
        var index = text.startIndex
        while let open = text.range(of: openTag, range: index..<text.endIndex) {
            result += text[index..<open.lowerBound]
            guard let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex) else {
                result += text[open.lowerBound...]
                return tidy(result)
            }
            if keepContent {
                let body = text[open.upperBound..<close.lowerBound]
                if let sep = body.range(of: separator) {
                    result += body[sep.upperBound...]
                } else {
                    result += body
                }
            }
            index = close.upperBound
        }
        result += text[index...]
        return tidy(result)
    }

    /// Collapses the blank lines left around inserted/removed blocks.
    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]*\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Encoding

    private static func encode<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return data.base64EncodedString()
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ string: String) -> T? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
