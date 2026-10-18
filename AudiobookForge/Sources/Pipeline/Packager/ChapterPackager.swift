import Foundation

struct ChapterAudioFile: Sendable {
    let chapter: Chapter
    let url: URL
}

enum PackagerError: LocalizedError {
    case ffmpegNotFound
    case ffmpegFailed(String)
    case noChapterAudio

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg wurde nicht gefunden. Bitte installieren (z. B. `brew install ffmpeg`) oder den Pfad in den Einstellungen überschreiben."
        case .ffmpegFailed(let message):
            return "ffmpeg-Aufruf fehlgeschlagen: \(message)"
        case .noChapterAudio:
            return "Es liegen keine fertigen Kapitel-Audiodateien zum Verpacken vor."
        }
    }
}

/// Narrow interface for turning per-chapter audio files into a final,
/// distributable output. Every output format is its own swappable
/// implementation behind this protocol.
protocol ChapterPackager: Sendable {
    func package(
        book: BookProject,
        chapterAudioFiles: [ChapterAudioFile],
        outputDirectory: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL
}

enum ChapterPackagerFactory {
    static func packager(for format: OutputFormat, settings: AppSettings) -> ChapterPackager {
        switch format {
        case .mp3Chapters:
            return MP3ChapterPackager(settings: settings)
        case .m4b:
            return MP4ChapterPackager(settings: settings, format: .m4b)
        case .m4a:
            return MP4ChapterPackager(settings: settings, format: .m4a)
        }
    }
}
