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

/// How chapter loudness is evened out (v4.4).
enum LoudnessMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// One fixed gain per chapter plus a peak limiter: the voice stays as
    /// the engine made it.
    case calm
    /// EBU R128 loudnorm: rides the gain continuously (the pre-4.4 way).
    case dynamic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calm: return L("Ruhig")
        case .dynamic: return L("Dynamisch")
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
    /// Phonon 40m (Gradium) via the ptts runtime (v4).
    case phonon
    /// Pocket TTS (Kyutai) via its official runtime, with local cloning (v4).
    case pocketTTS

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
        case .phonon: return L("Phonon (Gradium, sehr schnell, DE/EN/FR/ES)")
        case .pocketTTS: return L("Pocket TTS (Kyutai, schnell, DE/EN/FR/ES/IT, Klonen)")
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

extension TTSEngineID {
    /// Parallel chapter workers that measured fastest (v4 benchmarks,
    /// M5 Pro): Phonon saturates at ~4 single-thread processes, the MLX
    /// engines at 2 (GPU), OmniVoice needs ~4 GB per worker.
    var recommendedWorkers: Int {
        switch self {
        case .phonon: return 4
        // ~14x per single-thread process, ~30x with 4 (1 GB each).
        case .pocketTTS: return 3
        case .omniVoice, .appleSystem: return 1
        case .kokoro, .kokoroGerman, .kokoroThorsten, .supertonic3, .piper: return 2
        }
    }

    /// Engines that shipped before v4 (their worker count migrates from
    /// the former global `ttsParallelWorkers`).
    var isPreV4: Bool { self != .phonon && self != .pocketTTS }

    /// Upper bound offered in the settings.
    var maxWorkers: Int {
        switch self {
        case .phonon: return 8
        case .pocketTTS: return 6
        case .omniVoice: return 2
        case .appleSystem: return 1
        default: return 4
        }
    }
}

extension TTSEngineID {
    /// Throughput order (0 = fastest), from the v4 measurements.
    var speedRank: Int {
        switch self {
        case .phonon: return 0
        case .supertonic3: return 1
        case .appleSystem, .pocketTTS: return 2
        case .kokoro, .kokoroGerman, .kokoroThorsten: return 3
        case .piper: return 4
        case .omniVoice: return 5
        }
    }

    var supportsCloning: Bool { self == .pocketTTS || self == .omniVoice }

    /// Languages the engine speaks in this app (two-letter codes).
    var languageCodes: [String] {
        switch self {
        case .phonon: return ["de", "en", "fr", "es"]
        case .pocketTTS: return ["de", "en", "fr", "es", "it"]
        case .kokoro: return ["en", "fr", "es", "it"]
        case .kokoroGerman, .kokoroThorsten: return ["de"]
        case .piper: return ["de", "en"]
        case .supertonic3: return ["de", "en"]
        case .omniVoice: return ["de", "en", "fr", "es", "it"]
        case .appleSystem: return ["de", "en"]
        }
    }

    /// One-paragraph portrait for the gallery's engine view.
    var portrait: String {
        switch self {
        case .phonon: return L("Gradiums Phonon 40m: die schnellste Engine (viele Kapitel gleichzeitig auf der CPU), natürliche, gut verständliche Stimmen. Je Sprache ein kleines Modell (~78 MB). Nur nicht-kommerzielle Nutzung.")
        case .pocketTTS: return L("Kyutais Pocket TTS: schnell auf der CPU, fünf Sprachen, jede Stimme spricht jede Sprache. Klont eigene Stimmen lokal aus 10–20 Sekunden Aufnahme. Optional 24-Schichten-Modelle für mehr Natürlichkeit.")
        case .kokoro: return L("Kokoro (MLX): sehr schnell auf Apple Silicon, ausdrucksstarke englische Stimmen, dazu Französisch, Spanisch und Italienisch.")
        case .kokoroGerman, .kokoroThorsten: return L("Deutsche Kokoro-Feinabstimmungen (MLX): warme Erzählerstimmen, sehr schnell.")
        case .piper: return L("Piper: klein und robust, viele Community-Stimmen, Echtzeit-Tempo.")
        case .supertonic3: return L("Supertonic 3 (MLX): extrem schnell, gut für lange Sachtexte.")
        case .omniVoice: return L("OmniVoice: Diffusionsmodell mit 600+ Sprachen und Stimmklonen, langsamer, ~2 GB.")
        case .appleSystem: return L("macOS-Systemstimmen: ohne Download, mittlere Qualität; Premium-Stimmen in den Systemeinstellungen.")
        }
    }

    /// Model license in one line (v4.1), shown on the gallery's engine card.
    var license: String {
        switch self {
        case .phonon: return L("Lizenz: CC BY-NC 4.0 — nur nicht-kommerziell; Englisch 31M: Apache 2.0")
        case .pocketTTS: return L("Lizenz: CC BY 4.0 — Namensnennung (Kyutai)")
        case .kokoro, .kokoroGerman: return L("Lizenz: Apache 2.0")
        case .kokoroThorsten: return L("Lizenz: CC0 (Thorsten-Voice)")
        case .piper: return L("Lizenz: je nach Stimme (meist MIT oder CC)")
        case .supertonic3, .omniVoice: return L("Lizenz: siehe Modellkarte")
        case .appleSystem: return L("Lizenz: macOS-Systemstimmen")
        }
    }
}
