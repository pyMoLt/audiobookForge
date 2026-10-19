import Foundation

struct EPUBExtractor: DocumentExtractor {
    var settings: AppSettings = AppSettings()

    private var imageThresholds: PDFFigureDetector.Thresholds {
        PDFFigureDetector.Thresholds(
            minimumPixelSize: settings.minimumImageDimensionForVisionPass,
            minimumAreaFraction: 0,
            minimumKilobytes: settings.minimumImageKilobytes,
            maximumAspectRatio: settings.maximumImageAspectRatio,
            detectVectorFigures: false
        )
    }

    func extract(from url: URL) async throws -> ExtractedDocument {
        try await extractEPUBContents(url: url)
    }

    private func extractEPUBContents(url: URL) async throws -> ExtractedDocument {
        let workDir = try await unzip(epubURL: url)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let containerURL = workDir.appendingPathComponent("META-INF/container.xml")
        guard let containerDoc = try? XMLDocument(contentsOf: containerURL, options: []) else {
            throw DocumentExtractionError.unreadableDocument("container.xml fehlt oder ist ungültig")
        }
        guard let opfRelativePath = try containerDoc.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw DocumentExtractionError.unreadableDocument("Kein rootfile in container.xml gefunden")
        }

        let opfURL = workDir.appendingPathComponent(opfRelativePath)
        let opfDirectory = opfURL.deletingLastPathComponent()
        guard let opfDoc = try? XMLDocument(contentsOf: opfURL, options: []) else {
            throw DocumentExtractionError.unreadableDocument("OPF-Datei konnte nicht gelesen werden")
        }

        let title = (try? opfDoc.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").first?.stringValue)??
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = (try? opfDoc.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']").first?.stringValue)??
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var manifest: [String: (href: URL, mediaType: String, properties: String)] = [:]
        let manifestItems = (try? opfDoc.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? []
        for item in manifestItems {
            guard let element = item as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let hrefString = element.attribute(forName: "href")?.stringValue,
                  let href = URL(string: hrefString, relativeTo: opfDirectory)?.absoluteURL
            else { continue }
            let mediaType = element.attribute(forName: "media-type")?.stringValue ?? ""
            let properties = element.attribute(forName: "properties")?.stringValue ?? ""
            manifest[id] = (href, mediaType, properties)
        }

        var spineHrefs: [URL] = []
        let spineItems = (try? opfDoc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? []
        for item in spineItems {
            guard let element = item as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  let manifestEntry = manifest[idref]
            else { continue }
            spineHrefs.append(manifestEntry.href.standardizedFileURL)
        }

        guard !spineHrefs.isEmpty else {
            throw DocumentExtractionError.unreadableDocument("Kein Spine (Leseabfolge) in der OPF-Datei gefunden")
        }

        let tocEntries = resolveTableOfContents(manifest: manifest, opfDoc: opfDoc, opfDirectory: opfDirectory)

        let chapters = buildChapters(spineHrefs: spineHrefs, tocEntries: tocEntries, archiveRoot: workDir)
        guard !chapters.isEmpty else {
            throw DocumentExtractionError.emptyDocument
        }

        let coverData = findCoverImage(manifest: manifest, opfDoc: opfDoc)

        return ExtractedDocument(
            suggestedTitle: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
            suggestedAuthor: author,
            chapters: chapters,
            coverImageData: coverData,
            usedOCR: false
        )
    }

    // MARK: - Unzip

    private func unzip(epubURL: URL) async throws -> URL {
        try await Self.unzip(epubURL: epubURL)
    }

    /// Unpacks an EPUB into a fresh temporary directory (caller deletes).
    /// Also used at processing time to read figure images.
    static func unzip(epubURL: URL) async throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookForge-EPUB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-qq", "-o", epubURL.path, "-d", workDir.path]
            )
        } catch {
            throw DocumentExtractionError.unreadableDocument("unzip konnte nicht gestartet werden: \(error.localizedDescription)")
        }
        guard result.terminationStatus == 0 else {
            throw DocumentExtractionError.unreadableDocument(result.standardErrorText.isEmpty ? "unzip fehlgeschlagen" : result.standardErrorText)
        }

        return workDir
    }

    // MARK: - Table of contents

    private struct TOCEntry {
        let href: URL
        let fragment: String?
        let title: String
    }

    private func resolveTableOfContents(
        manifest: [String: (href: URL, mediaType: String, properties: String)],
        opfDoc: XMLDocument,
        opfDirectory: URL
    ) -> [TOCEntry] {
        if let navEntry = manifest.values.first(where: { $0.properties.contains("nav") }),
           let navDoc = try? XMLDocument(contentsOf: navEntry.href, options: []) {
            let entries = parseNav(navDoc: navDoc, navDirectory: navEntry.href.deletingLastPathComponent())
            if !entries.isEmpty { return entries }
        }

        let spineToc = (try? opfDoc.nodes(forXPath: "//*[local-name()='spine']/@toc"))?.first?.stringValue
        if let tocId = spineToc, let ncxEntry = manifest[tocId],
           let ncxDoc = try? XMLDocument(contentsOf: ncxEntry.href, options: []) {
            return parseNCX(ncxDoc: ncxDoc, ncxDirectory: ncxEntry.href.deletingLastPathComponent())
        }

        if let ncxEntry = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
           let ncxDoc = try? XMLDocument(contentsOf: ncxEntry.href, options: []) {
            return parseNCX(ncxDoc: ncxDoc, ncxDirectory: ncxEntry.href.deletingLastPathComponent())
        }

        return []
    }

    private func parseNav(navDoc: XMLDocument, navDirectory: URL) -> [TOCEntry] {
        guard let tocNav = (try? navDoc.nodes(forXPath: "//*[local-name()='nav'][@*[local-name()='type']='toc']"))?.first as? XMLElement else {
            return []
        }
        // Recursive descendant search (".//"), not just direct children of
        // the top-level <ol> — a nested TOC ("Book I" containing several
        // "Chapter" <li>s in their own sub-<ol>) is extremely common (any
        // book organized into parts/books, e.g. Mill's "A System of Logic")
        // and a direct-child-only query silently drops every nested entry,
        // leaving only the handful of top-level "Book" links — each then
        // spanning an entire book's worth of text as one giant "chapter."
        // Flattening into one ordered list and letting `buildChapters`
        // resolve each entry's own anchor is the same strategy already used
        // for nested PDF outlines.
        let allLinks = (try? tocNav.nodes(forXPath: ".//*[local-name()='li']/*[local-name()='a']")) ?? []
        return allLinks.compactMap { node -> TOCEntry? in
            guard let element = node as? XMLElement,
                  let hrefString = element.attribute(forName: "href")?.stringValue,
                  let href = URL(string: hrefString, relativeTo: navDirectory)?.absoluteURL
            else { return nil }
            let title = (element.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return TOCEntry(href: stripFragment(href), fragment: href.fragment, title: title)
        }
    }

    private func parseNCX(ncxDoc: XMLDocument, ncxDirectory: URL) -> [TOCEntry] {
        // Same nesting issue as the nav.xhtml case above: a `navPoint` can
        // itself contain child `navPoint`s (Book > Chapter), so this has to
        // search descendants at any depth, not just navMap's direct children.
        let navPoints = (try? ncxDoc.nodes(forXPath: "//*[local-name()='navMap']//*[local-name()='navPoint']")) ?? []
        return navPoints.compactMap { node -> TOCEntry? in
            guard let element = node as? XMLElement else { return nil }
            guard let contentSrc = (try? element.nodes(forXPath: "./*[local-name()='content']/@src"))?.first?.stringValue,
                  let href = URL(string: contentSrc, relativeTo: ncxDirectory)?.absoluteURL
            else { return nil }
            let title = ((try? element.nodes(forXPath: "./*[local-name()='navLabel']/*[local-name()='text']"))?.first?.stringValue ?? "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TOCEntry(href: stripFragment(href), fragment: href.fragment, title: title)
        }
    }

    private func stripFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.fragment = nil
        return components.url?.standardizedFileURL ?? url
    }

    // MARK: - Chapter assembly

    private func buildChapters(spineHrefs: [URL], tocEntries: [TOCEntry], archiveRoot: URL) -> [ExtractedChapter] {
        var entriesByHref: [URL: [TOCEntry]] = [:]
        for entry in tocEntries {
            entriesByHref[entry.href.standardizedFileURL, default: []].append(entry)
        }

        struct Section {
            var title: String
            var textParts: [String] = []
        }

        var sections: [Section] = []

        for href in spineHrefs {
            let entries = entriesByHref[href.standardizedFileURL] ?? []
            guard let data = try? Data(contentsOf: href) else { continue }
            let images = EPUBHTMLTextExtractor.ImageContext(documentURL: href, archiveRoot: archiveRoot, thresholds: imageThresholds)

            if entries.isEmpty {
                // No TOC entry targets this file at all — it's a
                // continuation of whatever chapter is currently open.
                let text = EPUBHTMLTextExtractor.extractText(from: data, images: images)
                if !text.isEmpty {
                    if sections.isEmpty {
                        sections.append(Section(title: "Einleitung", textParts: [text]))
                    } else {
                        sections[sections.count - 1].textParts.append(text)
                    }
                }
                continue
            }

            // One or more TOC entries target this file. Usually that means
            // one entry per whole file (most EPUBs), but Gutenberg-style
            // EPUBs frequently pack the entire book into one XHTML file
            // with the TOC pointing at in-file fragment anchors instead —
            // so this file may need to be sliced into several chapters.
            let blocks = EPUBHTMLTextExtractor.extractBlocksWithAnchors(from: data, images: images)
            guard !blocks.isEmpty else { continue }

            let splitPoints: [(title: String, blockIndex: Int)] = entries.compactMap { entry -> (title: String, blockIndex: Int)? in
                guard let fragment = entry.fragment else {
                    // No fragment at all — this entry addresses the whole
                    // file (normal when it's the only entry pointing here).
                    return (entry.title, 0)
                }
                guard let matchIndex = blocks.firstIndex(where: { $0.ids.contains(fragment) }) else {
                    // Anchor genuinely not found. Defaulting this to index 0
                    // used to be actively harmful: with several entries per
                    // file (common for a nested Book > Chapter TOC), every
                    // entry whose anchor failed to resolve collapsed onto
                    // the same position-0 split point, which after sorting
                    // corrupts the ordering of every OTHER entry in this
                    // file too and silently merges several real chapters
                    // into one. Dropping just this one entry only costs its
                    // own chapter boundary, and leaves every entry that DID
                    // resolve correctly alone.
                    return nil
                }
                return (entry.title, matchIndex)
            }.sorted { $0.blockIndex < $1.blockIndex }

            for (index, split) in splitPoints.enumerated() {
                let endIndex = index + 1 < splitPoints.count ? splitPoints[index + 1].blockIndex : blocks.count
                guard endIndex > split.blockIndex else { continue }
                let text = blocks[split.blockIndex..<endIndex].map(\.text).joined(separator: "\n\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                sections.append(Section(title: split.title.isEmpty ? "Kapitel \(sections.count + 1)" : split.title, textParts: [text]))
            }
        }

        return sections.compactMap { section -> ExtractedChapter? in
            let text = section.textParts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ExtractedChapter(title: section.title, text: text)
        }
    }

    private func findCoverImage(manifest: [String: (href: URL, mediaType: String, properties: String)], opfDoc: XMLDocument) -> Data? {
        if let coverMetaContent = (try? opfDoc.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='meta'][@name='cover']/@content"))?.first?.stringValue,
           let entry = manifest[coverMetaContent], entry.mediaType.hasPrefix("image/") {
            return try? Data(contentsOf: entry.href)
        }
        if let coverEntry = manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            return try? Data(contentsOf: coverEntry.href)
        }
        return nil
    }
}
