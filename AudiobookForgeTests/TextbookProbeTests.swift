import Foundation
import XCTest
@testable import AudiobookForge

/// Opt-in quality probe on real (user-owned, local) textbooks: imports the
/// document and writes chapter list, a text sample and quality counters to
/// `ABF_PROBE_OUT`. Nothing leaves the machine.
///   TEST_RUNNER_ABF_PROBE_FILE=/path/book.pdf TEST_RUNNER_ABF_PROBE_OUT=/path/out.txt
final class TextbookProbeTests: XCTestCase {
    func testProbeTextbookImport() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ABF_PROBE_FILE"], let out = env["ABF_PROBE_OUT"] else { throw XCTSkip("ABF_PROBE_* not set") }
        let started = Date()
        let book = try await DocumentImportService.importDocument(at: URL(fileURLWithPath: path), settings: AppSettings())
        let elapsed = Date().timeIntervalSince(started)
        let markedText = book.chapters.map(\.cleanedText).joined(separator: "\n\n")
        let text = PDFTextbookCleaner.removeCrossReferences(ImageDescriptionMarker.displayText(markedText))
        func count(_ pattern: String) -> Int {
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
        }
        var report = "file=\(path)\nimport_seconds=\(String(format: "%.1f", elapsed)) chapters=\(book.chapters.count) chars=\(text.count) images=\(book.detectedImageCount ?? -1) language=\(book.detectedLanguageCode ?? "nil") oldDetector=\(LanguageDetector.detectLanguageCode(sampleText: book.chapters.prefix(3).map(\.cleanedText).joined(separator: "\n").prefix(4000).description) ?? "nil")\n"
        report += "hyphen_linebreaks=\(count(#"\p{L}-\n\p{Ll}"#)) ligatures=\(count("[\u{FB00}-\u{FB06}]")) short_label_lines=\(count(#"^\S{1,4}\*?$"#)) figures=\(ImageDescriptionMarker.figures(in: markedText).count)\n"
        let shortLines = text.components(separatedBy: "\n").filter { $0.range(of: #"^\S{1,4}\*?$"#, options: .regularExpression) != nil }
        report += "short_lines_sample=" + shortLines.prefix(80).joined(separator: " | ") + "\n"
        report += "--- chapters ---\n" + book.chapters.prefix(400).map { "\($0.order): \($0.title) [\($0.cleanedText.count)]" }.joined(separator: "\n")
        let marker = env["ABF_PROBE_SAMPLE"] ?? "Apoptose. Die Apoptose"
        if let range = text.range(of: marker) {
            let start = text.index(range.lowerBound, offsetBy: -2500, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 1500, limitedBy: text.endIndex) ?? text.endIndex
            report += "\n--- sample ---\n" + String(text[start..<end])
        }
        try report.write(toFile: out, atomically: true, encoding: .utf8)
    }
}

/// Batch variant: imports every PDF/EPUB in `ABF_PROBE_DIR` (non-recursive) and
/// writes one summary file per document into `ABF_PROBE_OUTDIR`.
final class TextbookBatchProbeTests: XCTestCase {
    func testBatchProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ABF_PROBE_DIR"], let outDir = env["ABF_PROBE_OUTDIR"] else { throw XCTSkip("ABF_PROBE_DIR not set") }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { ["pdf", "epub"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        var summary = ""
        for name in files {
            let started = Date()
            do {
                let book = try await { () async throws -> BookProject in var st = AppSettings(); if let t = env["ABF_PROBE_TYPE"], let dt = DocumentType(rawValue: t) { st.defaultDocumentType = dt }; return try await DocumentImportService.importDocument(at: URL(fileURLWithPath: dir).appendingPathComponent(name), settings: st) }()
                let secs = Date().timeIntervalSince(started)
                let sizes = book.chapters.map { $0.cleanedText.count }
                let line = "\(name) | \(String(format: "%.1f", secs))s | chapters=\(book.chapters.count) | chars=\(sizes.reduce(0, +)) | min=\(sizes.min() ?? 0) max=\(sizes.max() ?? 0) | lang=\(book.detectedLanguageCode ?? "nil") | images=\(book.detectedImageCount ?? -1)"
                summary += line + "\n"
                let detail = line + "\n" + book.chapters.prefix(400).map { "\($0.order): \($0.title) [\($0.cleanedText.count)]" }.joined(separator: "\n") + "\n--- first chapter sample ---\n" + String((book.chapters.dropFirst(min(1, book.chapters.count - 1)).first?.cleanedText ?? "").prefix(1500))
                try detail.write(toFile: outDir + "/" + name + ".txt", atomically: true, encoding: .utf8)
            } catch {
                summary += "\(name) | ERROR \(error)\n"
            }
            try summary.write(toFile: outDir + "/_summary.txt", atomically: true, encoding: .utf8)
        }
    }
}
