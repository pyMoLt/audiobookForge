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
        case .appleSystem, .phonon, .pocketTTS:
            return .veryFast
        }
    }

    var languageGroup: String {
        switch String(languageCode.prefix(2)) {
        case "de": return "Deutsch"
        case "en": return "Englisch"
        case "fr": return "Französisch"
        case "es": return "Spanisch"
        case "it": return "Italienisch"
        default: return "Weitere"
        }
    }

    /// Two-letter language ("de", "en", "fr", "es", "it").
    var baseLanguage: String { String(languageCode.prefix(2)) }
}

/// Static catalog of known voices (plan 8.1). Quality grades for Kokoro EN
/// follow the official model card's VOICES.md grades (A … C), German
/// Kokoro/Piper grades come from our own listening tests and the community
/// documentation — see docs/TTS_RECHERCHE_V3.md for sources.
enum VoiceCatalog {
    static let germanSampleText = "Willkommen bei Ihrem Hörbuch. Diese Stimme liest Ihnen gleich Ihr Buch vor."
    static let englishSampleText = "Welcome to your audiobook. This voice will be reading your book in a moment."

    static let frenchSampleText = "Bienvenue dans votre livre audio. Cette voix va vous lire votre livre dans un instant."
    static let spanishSampleText = "Bienvenido a su audiolibro. Esta voz le leerá su libro en un momento."
    static let italianSampleText = "Benvenuti nel vostro audiolibro. Questa voce vi leggerà il libro tra un momento."

    static func sample(for languageCode: String) -> String {
        switch String(languageCode.prefix(2)) {
        case "de": return germanSampleText
        case "fr": return frenchSampleText
        case "es": return spanishSampleText
        case "it": return italianSampleText
        default: return englishSampleText
        }
    }

    /// Built once per launch (system voices installed later show up after a restart).
    static let allProfiles: [VoiceProfile] = kokoroEnglish + kokoroRomance + kokoroGerman + piperGerman + piperEnglish + supertonic + omniVoice + phonon + pocket + appleSystemVoices

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

    // Kokoro FR/ES/IT (v4) — same model, espeak-ng phonemes; grades from
    // the model card (B-/C), so "good" at best.
    private static let kokoroRomance: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "ff_siwis"), displayName: "Siwis", languageCode: "fr", gender: .female, tags: ["klar"], quality: .good, sampleText: frenchSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "ef_dora"), displayName: "Dora", languageCode: "es", gender: .female, tags: ["freundlich"], quality: .good, sampleText: spanishSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "em_alex"), displayName: "Alex", languageCode: "es", gender: .male, tags: ["ruhig"], quality: .ok, sampleText: spanishSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "em_santa"), displayName: "Santa", languageCode: "es", gender: .male, tags: ["tief"], quality: .ok, sampleText: spanishSampleText, featured: false),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "if_sara"), displayName: "Sara", languageCode: "it", gender: .female, tags: ["warm"], quality: .good, sampleText: italianSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .kokoro, voice: "im_nicola"), displayName: "Nicola", languageCode: "it", gender: .male, tags: ["Erzähler"], quality: .good, sampleText: italianSampleText, featured: true),
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
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-eva_k-x_low"), displayName: "Eva K.", languageCode: "de", gender: .female, tags: ["freundlich"], quality: .ok, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-karlsson-low"), displayName: "Karlsson", languageCode: "de", gender: .male, tags: ["sachlich"], quality: .ok, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-kerstin-low"), displayName: "Kerstin", languageCode: "de", gender: .female, tags: ["ruhig"], quality: .ok, sampleText: germanSampleText, featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-mls-medium"), displayName: "MLS", languageCode: "de", gender: .female, tags: ["Multi-Lingual"], quality: .ok, sampleText: germanSampleText, featured: false),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-pavoque-low"), displayName: "Pavoque", languageCode: "de", gender: .male, tags: ["neutral"], quality: .ok, sampleText: germanSampleText, featured: false),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "de_DE-ramona-low"), displayName: "Ramona", languageCode: "de", gender: .female, tags: ["weich"], quality: .ok, sampleText: germanSampleText, featured: false),
    ]

    // Piper EN
    private static let piperEnglish: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .piper, voice: "en_US-lessac-medium"), displayName: "Lessac", languageCode: "en-US", gender: .female, tags: ["neutral"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "en_US-ryan-high"), displayName: "Ryan", languageCode: "en-US", gender: .male, tags: ["Erzähler"], quality: .ok, sampleText: sample(for: "en"), featured: true),
        VoiceProfile(id: VoiceID(engine: .piper, voice: "en_GB-alba-medium"), displayName: "Alba", languageCode: "en-GB", gender: .female, tags: ["britisch"], quality: .ok, sampleText: sample(for: "en"), featured: false),
    ]

    // Supertonic 3 (MLX)
    private static let supertonic: [VoiceProfile] = [
        VoiceProfile(id: VoiceID(engine: .supertonic3, voice: "M1"), displayName: "Supertonic M1", languageCode: "de", gender: .male, tags: ["MLX"], quality: .good, sampleText: germanSampleText, featured: true),
    ]

    // Phonon 40m (Gradium, v4): Gradium's catalog for DE/EN/FR/ES; the top
    // two per locale and gender (Gradium's ranking) are featured.
    private static let phonon: [VoiceProfile] = PhononVoice.catalog.map { voice in
        let code = voice.locale.count == 5 && !["de-de", "fr-fr", "es-es"].contains(voice.locale)
            ? String(voice.locale.prefix(2)) + "-" + voice.locale.suffix(2).uppercased()
            : voice.language
        let rank = voice.rank ?? 99
        return VoiceProfile(id: VoiceID(engine: .phonon, voice: voice.id), displayName: voice.name, languageCode: code,
                            gender: voice.gender == "female" ? .female : .male,
                            tags: [], quality: rank <= 3 ? .top : .good,
                            sampleText: sample(for: voice.language), featured: rank <= 2)
    }

    // Pocket TTS (Kyutai, v4): every voice in every language; the native
    // voice of each language (Kyutai's own recording) is featured.
    private static let pocket: [VoiceProfile] = PocketEnvironmentManager.languages.flatMap { language in
        PocketVoice.all.map { voice in
            let native = PocketEnvironmentManager.nativeVoice(language, highQuality: false) == voice.name
            return VoiceProfile(id: VoiceID(engine: .pocketTTS, voice: "\(language)/\(voice.name)"), displayName: voice.displayName,
                                languageCode: language, gender: voice.female ? .female : .male,
                                tags: native ? ["Muttersprache", "Klon-fähig"] : ["Klon-fähig"],
                                quality: native ? .top : .good, sampleText: sample(for: language), featured: native)
        }
    }

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
                                languageCode: ["de", "fr", "es", "it"].contains(String(voice.language.prefix(2))) ? String(voice.language.prefix(2)) : voice.language,
                                gender: voice.gender == .male ? .male : .female,
                                tags: ["macOS", AppleSpeechEngine.qualityLabel(voice.quality)],
                                quality: premium ? .good : .ok,
                                sampleText: sample(for: voice.language),
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
        switch String(code.prefix(2)) {
        case "de": return VoiceID(engine: .kokoroGerman, voice: "martin")
        case "fr": return VoiceID(engine: .phonon, voice: "fr/Noémie")
        case "es": return VoiceID(engine: .phonon, voice: "es/Noa")
        case "it": return VoiceID(engine: .pocketTTS, voice: "it/marius")
        default: return VoiceID(engine: .kokoro, voice: "af_heart")
        }
    }

    // MARK: - Gallery (v4)

    /// Languages the gallery and the language switchers offer.
    static let galleryLanguages = ["de", "en", "fr", "es", "it"]

    static func profiles(language: String) -> [VoiceProfile] {
        allProfiles.filter { $0.baseLanguage == language }
    }

    enum Curation: String, CaseIterable, Identifiable {
        case quality, speed
        var id: String { rawValue }
        var title: String { self == .quality ? L("Beste Qualität") : L("Am schnellsten") }
    }

    /// The short, recommended list per language: the best-sounding voices,
    /// or the fastest engines' best voices — a few per engine so one engine
    /// doesn't fill the list.
    static func curated(_ curation: Curation, language: String, limit: Int = 6) -> [VoiceProfile] {
        let candidates = profiles(language: language).filter(\.featured)
        let sorted: [VoiceProfile]
        switch curation {
        case .quality:
            sorted = candidates.sorted {
                if $0.quality.points != $1.quality.points { return $0.quality.points > $1.quality.points }
                if $0.id.engine.speedRank != $1.id.engine.speedRank { return $0.id.engine.speedRank < $1.id.engine.speedRank }
                return $0.displayName < $1.displayName
            }
        case .speed:
            sorted = candidates.filter { $0.id.engine.speedRank <= 3 }.sorted {
                ($0.id.engine.speedRank, -$0.quality.points, $0.displayName) < ($1.id.engine.speedRank, -$1.quality.points, $1.displayName)
            }
        }
        var perEngine: [TTSEngineID: Int] = [:]
        var result: [VoiceProfile] = []
        for profile in sorted where result.count < limit {
            let used = perEngine[profile.id.engine, default: 0]
            guard used < 3 else { continue }
            perEngine[profile.id.engine] = used + 1
            result.append(profile)
        }
        return result
    }

    /// Engines that have voices in `language`.
    static func engines(language: String) -> [TTSEngineID] {
        TTSEngineID.allCases.filter { engine in profiles(language: language).contains { $0.id.engine == engine } }
    }
}
