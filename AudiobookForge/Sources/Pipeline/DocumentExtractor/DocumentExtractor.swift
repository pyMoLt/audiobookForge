import Foundation

/// Narrow, engine-independent plug point for turning a source document into
/// plain text + chapter structure. Every supported file format gets its own
/// implementation; the rest of the app only ever talks to this protocol.
protocol DocumentExtractor: Sendable {
    func extract(from url: URL) async throws -> ExtractedDocument
}

struct ExtractedChapter: Sendable, Equatable {
    var title: String
    var text: String
}

struct ExtractedDocument: Sendable, Equatable {
    var suggestedTitle: String
    var suggestedAuthor: String
    var chapters: [ExtractedChapter]
    var coverImageData: Data?
    var usedOCR: Bool = false
    var detectedImageCount: Int = 0
}

enum DocumentExtractionError: LocalizedError {
    case unreadableDocument(String)
    case unsupportedFormat(String)
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unreadableDocument(let reason):
            return "Dokument konnte nicht gelesen werden: \(reason)"
        case .unsupportedFormat(let ext):
            return "Nicht unterstütztes Dateiformat: \(ext)"
        case .emptyDocument:
            return "Es konnte kein Text aus dem Dokument extrahiert werden."
        }
    }
}

enum DocumentExtractorFactory {
    static func extractor(for url: URL, settings: AppSettings) -> DocumentExtractor? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return PDFExtractor(settings: settings)
        case "epub":
            return EPUBExtractor(settings: settings)
        default:
            return nil
        }
    }
}
