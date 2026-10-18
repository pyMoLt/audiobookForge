import Foundation
import ImageIO

/// Extracts readable plain text from an EPUB (X)HTML content document,
/// preserving paragraph breaks. EPUB content documents are required to be
/// well-formed XML, so we can use Foundation's XMLDocument instead of a
/// full HTML parser.
enum EPUBHTMLTextExtractor {
    /// Where the current content document lives inside the unpacked
    /// archive, so `<img src>` can be resolved to an archive path, plus the
    /// size filters an image must pass to become a figure placeholder.
    struct ImageContext {
        let documentURL: URL
        let archiveRoot: URL
        let thresholds: PDFFigureDetector.Thresholds
    }

    /// Figure placeholders for every qualifying image inside `element`
    /// (including `element` itself), in document order.
    private static func imagePlaceholders(in element: XMLElement, context: ImageContext?) -> [String] {
        guard let context else { return [] }
        var result: [String] = []
        func visit(_ node: XMLElement) {
            let name = (node.localName ?? node.name ?? "").lowercased()
            if name == "img" || name == "image" {
                let src = node.attribute(forName: "src")?.stringValue
                    ?? node.attribute(forName: "xlink:href")?.stringValue
                    ?? node.attribute(forName: "href")?.stringValue
                if let src, let placeholder = placeholder(src: src, element: node, context: context) {
                    result.append(placeholder)
                }
            }
            for case let child as XMLElement in node.children ?? [] { visit(child) }
        }
        visit(element)
        return result
    }

    private static func placeholder(src: String, element: XMLElement, context: ImageContext) -> String? {
        guard let url = URL(string: src, relativeTo: context.documentURL)?.absoluteURL.standardizedFileURL,
              url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "bmp", "heic"].contains(ext) else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var width = 0, height = 0
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        let t = context.thresholds
        guard min(width, height) >= t.minimumPixelSize, bytes >= t.minimumKilobytes * 1024,
              Double(max(width, height)) / Double(max(min(width, height), 1)) <= t.maximumAspectRatio else { return nil }
        let rootPath = context.archiveRoot.standardizedFileURL.path
        let relative = url.path.hasPrefix(rootPath + "/") ? String(url.path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
        let alt = element.attribute(forName: "alt")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = FigureReference(
            source: .epub, path: relative, kind: "raster",
            caption: figureCaption(around: element).map { String($0.prefix(600)) },
            altText: (alt?.isEmpty ?? true) ? nil : alt,
            pixelWidth: width, pixelHeight: height, encodedBytes: bytes
        )
        return ImageDescriptionMarker.placeholder(for: reference)
    }

    /// `<figcaption>` of the enclosing `<figure>` (up to three levels up).
    /// A table read cell by cell ("Na+", "Natrium", "OH–", …) is noise.
    /// Each row becomes one sentence instead: header cells pair with the
    /// row's values ("Ion: Na+, Name: Natrium-Ion.") when the table has a
    /// header row, otherwise the cells are simply joined.
    static func linearizedTableRows(_ table: XMLElement) -> [String] {
        let rows = ((try? table.nodes(forXPath: ".//*[local-name()='tr']")) ?? []).compactMap { $0 as? XMLElement }
        func cells(_ row: XMLElement) -> [String] {
            ((try? row.nodes(forXPath: "./*[local-name()='td' or local-name()='th']")) ?? []).map {
                normalizeBlockText($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let first = rows.first else { return [] }
        let firstCells = cells(first)
        let inThead = (first.parent as? XMLElement)?.localName?.lowercased() == "thead"
        let hasTH = ((try? first.nodes(forXPath: "./*[local-name()='th']")) ?? []).count > 0
        // Header row without markup: short, number-free labels above at
        // least two data rows.
        let looksLikeHeader = rows.count >= 3 && !firstCells.isEmpty
            && firstCells.allSatisfy { !$0.isEmpty && $0.count <= 30 && !$0.contains(where: \.isNumber) }
        let firstIsHeader = inThead || hasTH || looksLikeHeader
        let header = firstIsHeader ? firstCells : []
        var sentences: [String] = []
        for row in rows.dropFirst(firstIsHeader ? 1 : 0) {
            let values = cells(row)
            guard values.contains(where: { !$0.isEmpty }) else { continue }
            let parts: [String] = values.enumerated().compactMap { index, value in
                guard !value.isEmpty else { return nil }
                if header.indices.contains(index), !header[index].isEmpty { return "\(header[index]): \(value)" }
                return value
            }
            var sentence = parts.joined(separator: ", ")
            if let last = sentence.last, !".!?".contains(last) { sentence += "." }
            sentences.append(sentence)
        }
        return sentences
    }

    private static func figureCaption(around element: XMLElement) -> String? {
        var node: XMLNode? = element.parent
        for _ in 0..<3 {
            guard let current = node as? XMLElement else { return nil }
            if (current.localName ?? current.name ?? "").lowercased() == "figure",
               let caption = (try? current.nodes(forXPath: ".//*[local-name()='figcaption']"))?.first?.stringValue {
                return normalizeBlockText(caption).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            node = current.parent
        }
        return nil
    }

    private static let blockElementNames: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "blockquote", "td", "pre", "figcaption",
    ]

    /// `div` is deliberately not in `blockElementNames` — it's a generic
    /// container, not intrinsically a leaf of content. Some EPUBs (notably
    /// Gutenberg's TEI-derived HTML) wrap an entire chapter, or several
    /// consecutive headings and paragraphs, in nested `<div>`s. Treating
    /// `div` as a leaf the way `<p>` or `<h2>` are collapses that whole
    /// subtree — heading, body text, and every anchor `id` inside it — into
    /// ONE block. For plain text extraction that just loses paragraph
    /// breaks; for `extractBlocksWithAnchors` it's much worse: several
    /// different chapter headings' `id`s end up pointing at the exact same
    /// block index, so the TOC-driven split can't tell them apart and later
    /// chapters silently vanish into whichever one block index they all
    /// collapsed to. So a `div` is only ever treated as a leaf when it has
    /// no block-level content of its own to recurse into.
    private static func isLeafBlock(_ element: XMLElement, name: String) -> Bool {
        if blockElementNames.contains(name) { return true }
        if name == "div" { return !containsBlockElement(element) }
        return false
    }

    private static func containsBlockElement(_ element: XMLElement) -> Bool {
        for case let child as XMLElement in element.children ?? [] {
            let childName = (child.localName ?? child.name ?? "").lowercased()
            if blockElementNames.contains(childName) || childName == "div" {
                return true
            }
            if containsBlockElement(child) {
                return true
            }
        }
        return false
    }

    /// Collapses embedded hard line-wraps into spaces. The XML is parsed
    /// with `.nodePreserveWhitespace` (needed to keep real inter-word
    /// spacing intact), which means a source file that hard-wraps its prose
    /// at a fixed column — as Gutenberg's HTML does, at roughly 70
    /// characters, a holdover from the plain-text edition — carries those
    /// line breaks through as literal "\n" characters inside a single
    /// `<p>`'s own text. A paragraph's own text should never contain a
    /// meaningful internal line break; downstream, `NLTokenizer` (used for
    /// TTS sentence-splitting) treats any bare "\n" as a forced sentence
    /// boundary, so left in place this fragments one sentence into several
    /// synthesis segments — audible as a pause in the middle of a sentence.
    private static func normalizeBlockText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func extractText(from data: Data, images: ImageContext? = nil) -> String {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else {
            return fallbackStrip(data: data)
        }

        guard let root = document.rootElement() else { return "" }
        var blocks: [String] = []
        collectBlockText(from: root, into: &blocks, images: images)

        let joined = blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return joined
    }

    private static func collectBlockText(from node: XMLNode, into blocks: inout [String], images: ImageContext?) {
        guard let element = node as? XMLElement else { return }
        let name = (element.localName ?? element.name ?? "").lowercased()

        if name == "script" || name == "style" {
            return
        }

        if name == "img" || name == "image" {
            blocks.append(contentsOf: imagePlaceholders(in: element, context: images))
            return
        }

        if name == "table" {
            blocks.append(contentsOf: linearizedTableRows(element))
            blocks.append(contentsOf: imagePlaceholders(in: element, context: images))
            return
        }

        if isLeafBlock(element, name: name) {
            let text = normalizeBlockText(element.stringValue ?? "")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(text)
            }
            blocks.append(contentsOf: imagePlaceholders(in: element, context: images))
            return
        }

        for child in element.children ?? [] {
            collectBlockText(from: child, into: &blocks, images: images)
        }
    }

    /// Same block walk as `extractText`, but also reports which `id`
    /// attributes (from `<a id="...">`, `<h2 id="...">`, etc.) appear at or
    /// before each block. Needed to split a single content document at
    /// fragment-anchored TOC entries — common in Gutenberg-produced EPUBs,
    /// which often put a whole book in one XHTML file with the table of
    /// contents pointing at in-file anchors rather than separate files.
    static func extractBlocksWithAnchors(from data: Data, images: ImageContext? = nil) -> [(text: String, ids: [String])] {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]),
              let root = document.rootElement() else {
            let text = extractText(from: data, images: images)
            return text.isEmpty ? [] : [(text, [])]
        }
        var blocks: [(text: String, ids: [String])] = []
        var pendingIDs: [String] = []
        walkWithAnchors(root, blocks: &blocks, pendingIDs: &pendingIDs, images: images)
        return blocks
    }

    private static func walkWithAnchors(_ node: XMLNode, blocks: inout [(text: String, ids: [String])], pendingIDs: inout [String], images: ImageContext?) {
        guard let element = node as? XMLElement else { return }
        let name = (element.localName ?? element.name ?? "").lowercased()
        if name == "script" || name == "style" { return }

        if name == "img" || name == "image" {
            for placeholder in imagePlaceholders(in: element, context: images) {
                blocks.append((placeholder, pendingIDs))
                pendingIDs = []
            }
            return
        }

        if name == "table" {
            pendingIDs.append(contentsOf: collectNestedIDs(element))
            for row in linearizedTableRows(element) + imagePlaceholders(in: element, context: images) {
                blocks.append((row, pendingIDs))
                pendingIDs = []
            }
            return
        }

        if isLeafBlock(element, name: name) {
            pendingIDs.append(contentsOf: collectNestedIDs(element))
            let text = normalizeBlockText(element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append((text, pendingIDs))
                pendingIDs = []
            }
            for placeholder in imagePlaceholders(in: element, context: images) {
                blocks.append((placeholder, pendingIDs))
                pendingIDs = []
            }
            return
        }

        if let idValue = element.attribute(forName: "id")?.stringValue, !idValue.isEmpty {
            pendingIDs.append(idValue)
        }
        for child in element.children ?? [] {
            walkWithAnchors(child, blocks: &blocks, pendingIDs: &pendingIDs, images: images)
        }
    }

    private static func collectNestedIDs(_ element: XMLElement) -> [String] {
        var ids: [String] = []
        if let idValue = element.attribute(forName: "id")?.stringValue, !idValue.isEmpty {
            ids.append(idValue)
        }
        for case let child as XMLElement in element.children ?? [] {
            ids.append(contentsOf: collectNestedIDs(child))
        }
        return ids
    }

    private static func fallbackStrip(data: Data) -> String {
        guard let string = String(data: data, encoding: .utf8) else { return "" }
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: [.caseInsensitive]) else {
            return string
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: "\n")
    }
}
