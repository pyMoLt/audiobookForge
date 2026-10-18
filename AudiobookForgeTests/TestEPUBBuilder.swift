import Foundation

/// Builds a minimal, spec-valid EPUB3 (container.xml + OPF + nav + XHTML
/// chapters) for testing EPUBExtractor without a real-world file.
enum TestEPUBBuilder {
    static func makeBook(title: String, author: String, chapters: [(title: String, body: String)]) throws -> URL {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("epub-src-\(UUID().uuidString)", isDirectory: true)
        let metaInf = workDir.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = workDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        try "application/epub+zip".write(to: workDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        var manifestItems = ""
        var spineItems = ""
        var navItems = ""
        for (index, chapter) in chapters.enumerated() {
            let fileName = "chapter\(index + 1).xhtml"
            let chapterXHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>\(chapter.title)</title></head>
            <body>
            <h1>\(chapter.title)</h1>
            <p>\(chapter.body)</p>
            </body>
            </html>
            """
            try chapterXHTML.write(to: oebps.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
            manifestItems += "<item id=\"chap\(index + 1)\" href=\"\(fileName)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "<itemref idref=\"chap\(index + 1)\"/>\n"
            navItems += "<li><a href=\"\(fileName)\">\(chapter.title)</a></li>\n"
        }

        let navXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Nav</title></head>
        <body>
        <nav epub:type="toc">
        <ol>
        \(navItems)
        </ol>
        </nav>
        </body>
        </html>
        """
        try navXHTML.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            \(manifestItems)
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          </manifest>
          <spine>
            \(spineItems)
          </spine>
        </package>
        """
        try opf.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let epubURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).epub")
        try zip(sourceDirectory: workDir, destination: epubURL)
        try? FileManager.default.removeItem(at: workDir)
        return epubURL
    }

    private static func zip(sourceDirectory: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = sourceDirectory
        process.arguments = ["-qX", "-r", destination.path, "."]
        try process.run()
        process.waitUntilExit()
    }
}
