import Foundation

/// Identifies one concrete voice across engines (plan 8.1): the engine it
/// runs on plus the engine's own voice identifier, e.g. "kokoro:af_heart".
struct VoiceID: Hashable, Codable, Sendable, Equatable {
    var engine: TTSEngineID
    var voice: String

    init(engine: TTSEngineID, voice: String) {
        self.engine = engine
        self.voice = voice
    }
}

enum VoiceQuality: String, Codable, Sendable {
    case top
    case good
    case ok

    var points: Int {
        switch self {
        case .top: return 3
        case .good: return 2
        case .ok: return 1
        }
    }

    var label: String {
        switch self {
        case .top: return L("Hervorragend")
        case .good: return L("Gut")
        case .ok: return L("Okay")
        }
    }
}

enum VoiceGender: String, Codable, Sendable {
    case female
    case male

    var label: String {
        switch self {
        case .female: return L("Weiblich")
        case .male: return L("Männlich")
        }
    }
}

enum VoiceSpeed: String, Codable, Sendable {
    case veryFast = "sehr schnell"
    case nearRealtime = "nah an echtzeit"
    case realtime = "echtzeit"

    var label: String {
        switch self {
        case .veryFast: return L("Sehr schnell")
        case .nearRealtime: return L("Nah an Echtzeit")
        case .realtime: return L("Echtzeit")
        }
    }
}

/// One gallery entry (plan 8.1): everything the voice picker shows. The
/// engine is deliberately NOT part of the user-visible name — the gallery
/// speaks about voices, not implementations (engine only in tooltips).
struct VoiceProfile: Identifiable, Sendable, Equatable {
    let id: VoiceID
    let displayName: String
    /// BCP-47-ish: "de", "en-US", "en-GB".
    let languageCode: String
    let gender: VoiceGender
    let tags: [String]
    let quality: VoiceQuality
    /// Short sample sentence in the voice's language, for previews.
    let sampleText: String
    /// Voices presented up front rather than under "More voices".
    let featured: Bool

    var speed: VoiceSpeed {
        switch id.engine {
        case .kokoro, .kokoroGerman, .kokoroThorsten, .supertonic3:
            return .veryFast
        case .piper:
            return .realtime
        case .omniVoice:
            return .nearRealtime
        case .appleSystem:
            return .veryFast
        }
    }

    var languageGroup: String {
        switch languageCode {
        case "de": return "Deutsch"
        case let code where code.hasPrefix("en"): return "Englisch"
        default: return "Weitere"
        }
    }
}

/// Static catalog of known voices (plan 8.1). Quality grades for Kokoro EN
/// follow the official model card's VOICES.md grades (A … C), German
/// Kokoro/Piper grades come from our own listening tests and the community
/// documentation — see docs/TTS_RECHERCHE_V3.md for sources.
enum VoiceCatalog {
    static let germanSampleText = "Willkommen bei Ihrem Hörbuch. Diese Stimme liest Ihnen gleich Ihr Buch vor."
    static let englishSampleText = "Welcome to your audiobook. This voice will be reading your book in a moment."

    private static func sample(for languageCode: String) -> String {
        languageCode == "de" ? germanSampleText : englishSampleText
    }

    /// Built once per launch (system voices installed later show up after a restart).
    static let allProfiles: [VoiceProfile] = kokoroEnglish + kokoroGerman + piperGerman + piperEnglish + supertonic + omniVoice + appleSystemVoices

    // Kokoro EN — quality from the model card's VOICES.md grades.
    private static let kokoroEnglish: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "af_heart"), displayName: "Heart", languageCode: "en-US", gender: .female, tags: ["warm", "Erzählerin"], quality: .top, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "af_bella"), displayName: "Bella", languageCode: "en-US", gender: .female, tags: ["freundlich"], quality: .top, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "af_nicole"), displayName: "Nicole", languageCode: "en-US", gender: .female, tags: ["ruhig"], quality: .good, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "bf_emma"), displayName: "Emma", languageCode: "en-GB", gender: .female, tags: ["britisch"], quality: .good, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "am_michael"), displayName: "Michael", languageCode: "en-US", gender: .male, tags: ["Erzähler"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "am_fenrir"), displayName: "Fenrir", languageCode: "en-US", gender: .male, tags: ["kraftvoll"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "am_puck"), displayName: "Puck", languageCode: "en-US", gender: .male, tags: ["lebendig"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "bm_george"), displayName: "George", languageCode: "en-GB", gender: .male, tags: ["britisch"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "bm_fable"), displayName: "Fable", languageCode: "en-GB", gender: .male, tags: ["Geschichten"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "af_alloy"), displayName: "Alloy", languageCode: "en-US", gender: .female, tags: ["neutral"], quality: .ok, sampleText: sample(for: "en"), featured: false),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "af_sarah"), displayName: "Sarah", languageCode: "en-US", gender: .female, tags: ["klar"], quality: .ok, sampleText: sample(for: "en"), featured: false),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "af_sky"), displayName: "Sky", languageCode: "en-US", gender: .female, tags: ["hell"], quality: .ok, sampleText: sample(for: "en"), featured: false),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "am_adam"), displayName: "Adam", languageCode: "en-US", gender: .male, tags: ["neutral"], quality: .ok, sampleText: sample(for: "en"), featured: false),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "am_onyx"), displayName: "Onyx", languageCode: "en-US", gender: .male, tags: ["tief"], quality: .ok, sampleText: sample(for: "en"), featured: false),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "bf_lily"), displayName: "Lily", languageCode: "en-GB", gender: .female, tags: ["weich"], quality: .ok, sampleText: sample(for: "en"), featured: false),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "bm_daniel"), displayName: "Daniel", languageCode: "en-GB", gender: .male, tags: ["sachlich"], quality: .ok, sampleText: sample(for: "en"), featured: false),
    ]

    // Kokoro DE — MLX fine-tunes installed by the app's setup.
    private static let kokoroGerman: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .kokoroGerman, voice: "martin"), displayName: "Martin", languageCode: "de", gender: .male, tags: ["warm", "Erzähler"], quality: .top, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoroGerman, voice: "victoria"), displayName: "Victoria", languageCode: "de", gender: .female, tags: ["klar", "Erzählerin"], quality: .good, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoroThorsten, voice: "thorsten"), displayName: "Thorsten", languageCode: "de", gender: .male, tags: ["ruhig"], quality: .good, sampleText: germanSampleText, featured: true),
    ]

    // Piper DE — rhasspy/piper-voices, downloadable via the environment
    // manager (never silently; see PiperEnvironmentManager.downloadVoice).
    private static let piperGerman: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-thorsten-medium"), displayName: "Thorsten (mittel)", languageCode: "de", gender: .male, tags: ["Erzähler"], quality: .good, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-thorsten-high"), displayName: "Thorsten (hoch)", languageCode: "de", gender: .male, tags: ["Erzähler", "höchste Qualität"], quality: .good, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-thorsten_emotional-medium"), displayName: "Thorsten Emotional", languageCode: "de", gender: .male, tags: ["emotional"], quality: .ok, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-eva_k-medium"), displayName: "Eva K.", languageCode: "de", gender: .female, tags: ["freundlich"], quality: .ok, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-karlsson-medium"), displayName: "Karlsson", languageCode: "de", gender: .male, tags: ["sachlich"], quality: .ok, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-kerstin-low"), displayName: "Kerstin", languageCode: "de", gender: .female, tags: ["ruhig"], quality: .ok, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-mls-medium"), displayName: "MLS", languageCode: "de", gender: .female, tags: ["Multi-Lingual"], quality: .ok, sampleText: germanSampleText, featured: false),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-pavoque-medium"), displayName: "Pavoque", languageCode: "de", gender: .male, tags: ["neutral"], quality: .ok, sampleText: germanSampleText, featured: false),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-ramona-medium"), displayName: "Ramona", languageCode: "de", gender: .female, tags: ["weich"], quality: .ok, sampleText: germanSampleText, featured: false),
    ]

    // Piper EN
    private static let piperEnglish: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .piper, voice: "en_US-lessac-medium"), displayName: "Lessac", languageCode: "en-US", gender: .female, tags: ["neutral"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "en_US-ryan-high"), displayName: "Ryan", languageCode: "en-US", gender: .male, tags: ["Erzähler"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "en_GB-alba-medium"), displayName: "Alba", languageCode: "en-GB", gender: .female, tags: ["britisch"], quality: .ok, sampleText: sample(for: "en"), featured: false),
    ]

    // Supertonic 3 (MLX)
    private static let supertonic: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .supertonic3, voice: "M1"), displayName: "Supertonic M1", languageCode: "de", gender: .male, tags: ["sehr schnell", "MLX"], quality: .good, sampleText: germanSampleText, featured: true),
    ]

    // OmniVoice (k2-fsa) — one default voice for now; cloning later.
    // User listening test 2026-10-18: "klingt gut" — German among the
    // model's best-quality languages.
    private static let omniVoice: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .omniVoice, voice: "default"), displayName: "OmniVoice", languageCode: "de", gender: .female, tags: ["klar", "Klon-fähig", "600+ Sprachen"], quality: .good, sampleText: germanSampleText, featured: true),
    ]

    /// macOS system voices installed on this Mac (German/English), best
    /// quality first — computed at runtime, they differ per machine.
    static var appleSystemVoices: [VoiceProfile] {
        AppleSpeechEngine.installedVoices().map { voice in
            let premium = voice.quality == .premium
            return VoiceProfile(id: VoiceID(engine: .appleSystem, voice: voice.identifier), displayName: voice.name,
                                languageCode: voice.language.hasPrefix("de") ? "de" : voice.language,
                                gender: voice.gender == .male ? .male : .female,
                                tags: ["macOS", AppleSpeechEngine.qualityLabel(voice.quality)],
                                quality: premium ? .good : .ok,
                                sampleText: voice.language.hasPrefix("de") ? germanSampleText : englishSampleText,
                                featured: premium)
        }
    }

    static func profile(for id: VoiceID) -> VoiceProfile? {
        allProfiles.first { $0.id == id }
    }

    static func profiles(languageGroup: String) -> [VoiceProfile] {
        allProfiles.filter { $0.languageGroup == languageGroup }
    }

    static var languageGroups: [String] {
        var groups: [String] = []
        for profile in allProfiles where !groups.contains(profile.languageGroup) {
            groups.append(profile.languageGroup)
        }
        return groups
    }

    /// Sane default for a language when no stored default exists yet.
    static func defaultVoice(forLanguage code: String) -> VoiceID {
        switch code {
        case "de": return VoiceID(engine: .kokoroGerman, voice: "martin")
        default: return VoiceID(engine: .kokoro, voice: "af_heart")
        }
    }
}
