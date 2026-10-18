import Foundation

enum SourceDocumentType: String, Codable, Sendable {
    case pdf
    case epub
}

enum ProcessingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case transcription
    case summary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcription: return "Transkription"
        case .summary: return "Zusammenfassung"
        }
    }
}

enum OutputFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case m4b
    case m4a
    case mp3Chapters

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .m4b: return "M4B (Hörbuch, ein File)"
        case .m4a: return "M4A (ein File, ohne Audiobook-Flag)"
        case .mp3Chapters: return "MP3-Kapitel-Ordner"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4b: return "m4b"
        case .m4a: return "m4a"
        case .mp3Chapters: return "mp3"
        }
    }
}

enum TTSEngineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case kokoro
    case piper
    case kokoroGerman
    case kokoroThorsten
    case supertonic3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kokoro: return "Kokoro (lokal, via mlx-audio)"
        case .piper: return "Piper (lokal, deutsche & weitere Stimmen)"
        case .kokoroGerman: return "Kokoro Deutsch (MLX: Martin/Victoria)"
        case .kokoroThorsten: return "Kokoro Thorsten (MLX)"
        case .supertonic3: return "Supertonic 3 (MLX)"
        }
    }
}

enum BookProjectStatus: String, Codable, Sendable {
    case needsReview
    case queued
    case processing
    case paused
    case completed
    case failed
}

enum PipelineStage: String, Codable, Sendable {
    case extracting
    case describingImages
    case summarizing
    case synthesizing
    case packaging
    case done
    case failed

    var displayName: String {
        switch self {
        case .extracting: return "Einlesen"
        case .describingImages: return "Bilder beschreiben"
        case .summarizing: return "Zusammenfassen"
        case .synthesizing: return "Vorlesen"
        case .packaging: return "Verpacken"
        case .done: return "Fertig"
        case .failed: return "Fehlgeschlagen"
        }
    }
}

enum ChapterAudioStatus: String, Codable, Sendable {
    case pending
    case summarizing
    case synthesizing
    case ready
    case failed
}
