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
        case .transcription: return L("Transkription")
        case .summary: return L("Zusammenfassung")
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
        case .m4b: return L("M4B (Hörbuch, ein File)")
        case .m4a: return L("M4A (ein File, ohne Audiobook-Flag)")
        case .mp3Chapters: return L("MP3-Kapitel-Ordner")
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
    case omniVoice
    /// macOS system voices (AVSpeechSynthesizer), incl. Premium voices.
    case appleSystem

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kokoro: return L("Kokoro (lokal, via mlx-audio)")
        case .piper: return L("Piper (lokal, deutsche & weitere Stimmen)")
        case .kokoroGerman: return L("Kokoro Deutsch (MLX: Martin/Victoria)")
        case .kokoroThorsten: return L("Kokoro Thorsten (MLX)")
        case .supertonic3: return L("Supertonic 3 (MLX)")
        case .omniVoice: return L("OmniVoice (MLX, 600+ Sprachen)")
        case .appleSystem: return L("macOS-Systemstimmen (schnell, mittlere Qualität)")
        }
    }

    /// Books (and settings) written by a newer app version can contain an
    /// engine this build doesn't know — decode those as the default engine
    /// instead of throwing away the whole book record (plan 8.7).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // "qwen3" was removed (v3.2): its books and clone choices continue
        // on OmniVoice, the remaining cloning engine.
        if raw == "qwen3" { self = .omniVoice; return }
        self = TTSEngineID(rawValue: raw) ?? .kokoro
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
        case .extracting: return L("Einlesen")
        case .describingImages: return L("Bilder beschreiben")
        case .summarizing: return L("Zusammenfassen")
        case .synthesizing: return L("Vorlesen")
        case .packaging: return L("Verpacken")
        case .done: return L("Fertig")
        case .failed: return L("Fehlgeschlagen")
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
