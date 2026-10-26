import Foundation
import NaturalLanguage

/// Detects the dominant language of an extracted document using the native
/// NaturalLanguage framework (no network, no extra dependency). Used only to
/// suggest a matching TTS engine/voice — never to block anything, since the
/// heuristic can be wrong on short or mixed-language text.
enum LanguageDetector {
    /// Selectable languages (ISO 639-1) with German display names.
    static let selectableLanguages: [String] = ["de", "en", "fr", "es", "it", "nl", "pt", "pl", "sv", "da", "no", "fi", "cs", "tr", "ru"]

    static func displayName(_ code: String) -> String {
        Locale(identifier: "de").localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// English language name for prompts ("German", "English").
    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "German"
    }

    /// Detects the language of a whole book from samples out of its
    /// longest chapters (the start of a book is cover, imprint, preface —
    /// often in another language or mostly names). Figure markers are
    /// stripped first: their encoded payload was once read as Polish.
    static func detectLanguageCode(chapterTexts: [String]) -> String? {
        let cleaned = chapterTexts.map { ImageDescriptionMarker.stripBlocks(from: $0) }
        let samples = cleaned.sorted { $0.count > $1.count }.prefix(6).map { text -> String in
            guard text.count > 3000 else { return text }
            let start = text.index(text.startIndex, offsetBy: text.count / 2 - 1500)
            return String(text[start..<text.index(start, offsetBy: 3000)])
        }
        return detectLanguageCode(sampleText: samples.joined(separator: "\n\n"))
    }

    static func detectLanguageCode(sampleText: String) -> String? {
        let sample = String(ImageDescriptionMarker.stripBlocks(from: sampleText).prefix(20000))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return nil }
        return language.rawValue
    }

    /// Picks a sensible default engine + voice for a freshly imported book,
    /// based on the detected language and the language-level default voices
    /// (plan 8.2): German → `defaultVoiceDE`, English → `defaultVoiceEN`,
    /// everything else → the globally configured engine/voice.
    static func suggestEngineAndVoice(languageCode: String?, settings: AppSettings) -> (engine: TTSEngineID, voice: String) {
        guard settings.autoSelectEngineByLanguage, let languageCode else {
            return (settings.ttsEngine, settings.defaultVoice(for: settings.ttsEngine))
        }
        if languageCode.hasPrefix("de") {
            let voice = settings.defaultVoiceDE
            return (voice.engine, voice.voice)
        }
        if languageCode.hasPrefix("en") {
            let voice = settings.defaultVoiceEN
            return (voice.engine, voice.voice)
        }
        // v4: French, Spanish, Italian have their own default voices.
        if VoiceCatalog.galleryLanguages.contains(String(languageCode.prefix(2))) {
            let voice = settings.defaultVoiceID(forLanguage: languageCode)
            return (voice.engine, voice.voice)
        }
        return (settings.ttsEngine, settings.defaultVoice(for: settings.ttsEngine))
    }
}
