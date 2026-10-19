import Foundation

/// Settings areas (v3.1). Shown in the main sidebar while the settings are
/// open — one navigation instead of a second grey column (template:
/// grouped sections "Dictation / Text / Library / App").
enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case voices
    case speech
    case output
    case text
    case ai
    case images
    case appearance
    case engines
    case diagnostics

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case audiobook = "Hörbuch"
        case text = "Text & KI"
        case app = "App"
        var id: String { rawValue }
        var displayName: String { L(rawValue) }
    }

    var group: Group {
        switch self {
        case .voices, .speech, .output: return .audiobook
        case .text, .ai, .images: return .text
        case .appearance, .engines, .diagnostics: return .app
        }
    }

    var title: String {
        switch self {
        case .voices: return L("Stimmen")
        case .speech: return L("Sprechfluss")
        case .output: return L("Ausgabe")
        case .text: return L("Textaufbereitung")
        case .ai: return L("KI & Zusammenfassung")
        case .images: return L("Bilder")
        case .appearance: return L("Erscheinungsbild")
        case .engines: return L("Engines & Leistung")
        case .diagnostics: return L("Diagnose")
        }
    }

    var systemImage: String {
        switch self {
        case .voices: return "person.wave.2"
        case .speech: return "text.word.spacing"
        case .output: return "shippingbox"
        case .text: return "doc.text"
        case .ai: return "sparkles"
        case .images: return "photo.on.rectangle"
        case .appearance: return "paintpalette"
        case .engines: return "cpu"
        case .diagnostics: return "stethoscope"
        }
    }

    var subtitle: String {
        switch self {
        case .voices: return L("Standardstimmen für Deutsch und Englisch, Galerie und eigene Stimmen")
        case .speech: return L("Pausen, Tempo und Klang der Sprach-Engines")
        case .output: return L("Format, Zielordner, Qualität und Lautheit")
        case .text: return L("Kopf-/Fußzeilen, Fußnoten, Kapitelgrößen und Dokumenttypen")
        case .ai: return L("Lokales Sprachmodell, Gliederung, Zusammenfassung und Vorlagen")
        case .images: return L("Bildbeschreibungen mit dem Vision-Modell")
        case .appearance: return L("Hell oder dunkel, Textgröße, Akzentfarbe, Glas und Bewegung")
        case .engines: return L("Fallback-Engine, Modelle, Downloads und parallele Worker")
        case .diagnostics: return L("Umgebung, Abhängigkeiten und Protokolle")
        }
    }

    /// Search keywords (lowercase) — the sidebar search filters panes by
    /// these (plan 9.3: "Timeout" finds the connection/request timeouts).
    var keywords: String {
        switch self {
        case .voices: return "stimme stimmen galerie standard deutsch englisch klon klonen aufnahme hörprobe probe sprache"
        case .speech: return "sprechfluss pause satz absatz überschrift liste kapitel tempo geschwindigkeit kokoro piper supertonic omnivoice jitter"
        case .output: return "ausgabe format m4b mp3 aac bitrate ordner zielordner lautheit lufs normalisieren kapitel-audio qualität"
        case .text: return "text kapitel kopfzeile fußzeile fußnoten box label nummern dokumenttyp paper buch report literatur aufteilen gliederung"
        case .ai: return "ki llm sprachmodell omlx lm studio endpoint server verbindung timeout antwort modell zusammenfassung prompt vorlagen kontext"
        case .images: return "bild bilder abbildung vision beschreibung grafik diagramm"
        case .appearance: return "erscheinungsbild hell dunkel textgröße schrift akzent farbe glas bewegung hintergrund sidebar gruppierung"
        case .engines: return "engine engines modell download worker parallel fallback kokoro piper supertonic qwen omnivoice leistung"
        case .diagnostics: return "diagnose umgebung ffmpeg bridge python abhängigkeiten log protokoll pfad"
        }
    }

    /// English search words (the UI can run in English).
    var englishKeywords: String {
        switch self {
        case .voices: return "voice voices gallery default german english clone recording sample preview"
        case .speech: return "speech pause pauses sentence paragraph heading tempo speed rhythm"
        case .output: return "output format folder bitrate loudness quality export"
        case .text: return "text chapter header footer footnotes box labels numbers document type split cleanup"
        case .ai: return "ai llm model server connection timeout summary prompt templates context thinking"
        case .images: return "image images figure vision description diagram"
        case .appearance: return "appearance light dark text size accent color glass motion background language"
        case .engines: return "engine engines model download worker parallel fallback performance"
        case .diagnostics: return "diagnostics environment dependencies log path setup"
        }
    }

    /// Query matcher shared with the tests: each query word is a substring
    /// of the keywords, or the whole query is.
    func matches(_ query: String) -> Bool {
        let lowered = query.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.isEmpty { return true }
        let haystack = keywords + " " + englishKeywords + " " + title.lowercased()
        return haystack.contains(lowered) || lowered.split(separator: " ").contains { haystack.contains($0) }
    }
}
