import Foundation

enum LLMProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case lmStudio
    case omlx

    var id: String { rawValue }
    var displayName: String { self == .lmStudio ? "LM Studio" : "oMLX" }
    /// LM Studio's documented default; for oMLX whatever its own config
    /// says (falls back to oMLX's default 8000).
    var defaultBaseURL: String {
        self == .lmStudio ? "http://localhost:1234/v1" : (OMLXLocalConfig.serverBaseURL() ?? "http://127.0.0.1:8000/v1")
    }
}

enum OutputFolderTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case titleOnly
    case authorThenTitle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .titleOnly: return "Nur Titel"
        case .authorThenTitle: return "Autor/Titel"
        }
    }

    func relativePath(title: String, author: String) -> String {
        let safeTitle = OutputFolderTemplate.sanitize(title)
        switch self {
        case .titleOnly:
            return safeTitle
        case .authorThenTitle:
            let safeAuthor = OutputFolderTemplate.sanitize(author.isEmpty ? "Unbekannt" : author)
            return "\(safeAuthor)/\(safeTitle)"
        }
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.isEmpty ? "Unbenannt" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:\\")
        return cleaned.components(separatedBy: invalidCharacters).joined(separator: "-")
    }
}

/// The summarization prompt design here is deliberately the result of a live
/// test round against the user's actual local model (Qwen3.6-35B-A3B via LM
/// Studio), not a generic best-practice guess. Findings that shaped it:
/// - Percentage/ratio targets ("summarize to 25%") are effectively ignored by
///   this class of model — it undershoots by 2-3x regardless of the number.
/// - An explicit "preserve maximum detail, only trim redundancy" framing
///   reliably produces denser, more faithful output than any ratio or
///   discrete brief/moderate/detailed instruction tried.
/// - Central, repeated ideas survive compression well either way; it's
///   one-off granular facts (numbers, single-mention specifics) that get
///   lost — max-detail framing measurably helps here too.
/// So there is deliberately only one summarization style, not a detail-level
/// picker: "as dense as possible without losing information," full stop.
/// One unified prompt for every summarization call — single chapter or a
/// multi-chapter batch, normal-sized or an oversized item split further at
/// paragraph boundaries. The model is asked to insert its own "## heading"
/// markers at natural topic changes as it condenses; the app parses those
/// out afterward to build the actual chapter/navigation structure, rather
/// than the app dictating section boundaries up front. This replaced an
/// earlier design where the app pre-labeled each original chapter with an
/// opaque `<<<SEC:n>>>` tag and asked the model to echo it back — the app's
/// own author preferred letting the model organize the compressed content
/// itself instead of forcing a 1:1 map back onto (often too-fine or messy)
/// extracted PDF/EPUB section boundaries. Losing an exact per-input-chapter
/// guarantee is an accepted tradeoff: worst case a batch comes back with no
/// headings at all and becomes one coarser chapter, never lost content.
struct PromptTemplates: Codable, Sendable, Equatable {
    var systemPrompt: String = PromptTemplates.defaultSystemPrompt
    var userPromptTemplate: String = PromptTemplates.defaultUserPromptTemplate
    var visionPrompt: String = PromptTemplates.defaultVisionPrompt
    var visionPromptShort: String = PromptTemplates.defaultVisionPromptShort

    init() {}

    private enum CodingKeys: String, CodingKey {
        case systemPrompt, userPromptTemplate, visionPrompt, visionPromptShort
    }

    // Decodes missing keys as the current default rather than throwing, so
    // adding a field here later never invalidates an already-saved
    // settings.json (see `AppSettings.init(from:)` for the same reasoning).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? PromptTemplates.defaultSystemPrompt
        systemPrompt = PromptTemplates.legacyDefaultSystemPrompts.contains(savedPrompt) ? PromptTemplates.defaultSystemPrompt : savedPrompt
        userPromptTemplate = try container.decodeIfPresent(String.self, forKey: .userPromptTemplate) ?? PromptTemplates.defaultUserPromptTemplate
        visionPrompt = try container.decodeIfPresent(String.self, forKey: .visionPrompt) ?? PromptTemplates.defaultVisionPrompt
        visionPromptShort = try container.decodeIfPresent(String.self, forKey: .visionPromptShort) ?? PromptTemplates.defaultVisionPromptShort
    }

    // Structure part revised 2026-10-04 after an A/B run against
    // Qwen3.6-35B on oMLX (Attention paper, thinking off, 2 runs each): the
    // earlier wording ("insert a heading at major topic transitions") gave
    // 1, 3 or 10 headings; asking to *start* with a heading and use one per
    // main section gave a stable 6–9 chapters and kept more detail.
    // The listening rules make the output TTS-safe regardless of engine:
    // TTS front ends read digits, symbols and abbreviations inconsistently
    // (German years, decimals, "et al.", "%", citations), the LLM does it
    // reliably when told to. Model-agnostic on purpose.
    static let defaultSystemPrompt = """
    You are a precise summarization assistant preparing narration text for an audiobook. \
    Condense the given text while preserving as much fine-grained detail, as many named facts, \
    figures, numbers, and nuances as possible — omit only redundancy, repetition, and purely \
    stylistic padding. Do not produce a short abstract; produce a denser but still comprehensive \
    retelling that keeps the original's specifics intact wherever feasible.

    Structure your output into chapters for the audiobook's navigation. Start with a heading, and \
    begin a new heading wherever the source moves on to a new major section or topic — for a paper \
    or report that typically means one heading per main section (for example introduction, \
    background, method, results, discussion). Each chapter should cover a coherent topic; avoid both \
    one giant chapter and tiny micro-chapters. A heading is exactly "## " followed by a short \
    descriptive title, alone on its own line.

    Everything you write will be read aloud by a text-to-speech voice, so write for the ear:
    - Write all numbers as words in the language of the text: counts, years, dates, decimals, \
    percentages, ranges, currencies and units (for example "twenty-one", "nineteen ninety-nine", \
    "three point five millimetres", "zwölf Prozent", "am dritten Oktober zweitausendsechsundzwanzig").
    - Expand abbreviations and symbols into spoken words ("for example" instead of "e.g.", \
    "and colleagues" instead of "et al.", "Doktor" instead of "Dr.", "plus or minus" instead of "±"). \
    Introduce an acronym once in full, then use it as it is normally spoken.
    - Do not reproduce formulas, equations, variable names, code, URLs, DOIs, citation markers \
    such as [12] or (Smith et al., 2019), footnote numbers, or references to figures and tables \
    such as "see Fig. 3". Instead, explain in plain words what a formula expresses or what a figure \
    or table shows, including its key values.
    - Avoid parentheses, slashes and dashes used as brackets; fold that information into the \
    sentence. Prefer clear sentences of moderate length.
    - Paragraphs that begin with "Abbildung:" or "Figure:" are short descriptions of images in the \
    source. Use their information where it helps the listener follow the text, in your own words, \
    or leave them out if they add nothing.

    Between headings, write complete, natural, flowing prose suitable for narration: no bullet \
    points, no tables, no other markdown formatting. Never write about the sectioning or headings \
    themselves — no meta-commentary, no preamble, no closing remarks, just the headings and the \
    narration text. Write in the same language as the source text, regardless of the language of \
    this instruction.
    """

    /// Earlier built-in defaults. A saved prompt identical to one of these
    /// was never customized by the user, so it's upgraded to the current
    /// default on load instead of freezing an outdated prompt forever.
    static let legacyDefaultSystemPrompts: [String] = [
        """
        You are a precise summarization assistant preparing narration text for an audiobook. \
        Condense the given text while preserving as much fine-grained detail, as many named facts, \
        figures, numbers, and nuances as possible — omit only redundancy, repetition, and purely \
        stylistic padding. Do not produce a short abstract; produce a denser but still comprehensive \
        retelling that keeps the original's specifics intact wherever feasible.

        Structure your output into chapters for the audiobook's navigation. Start with a heading, and \
        begin a new heading wherever the source moves on to a new major section or topic — for a paper \
        or report that typically means one heading per main section (for example introduction, \
        background, method, results, discussion). Each chapter should cover a coherent topic; avoid both \
        one giant chapter and tiny micro-chapters. A heading is exactly "## " followed by a short \
        descriptive title, alone on its own line.

        Everything you write will be read aloud by a text-to-speech voice, so write for the ear:
        - Write all numbers as words in the language of the text: counts, years, dates, decimals, \
        percentages, ranges, currencies and units (for example "twenty-one", "nineteen ninety-nine", \
        "three point five millimetres", "zwölf Prozent", "am dritten Oktober zweitausendsechsundzwanzig").
        - Expand abbreviations and symbols into spoken words ("for example" instead of "e.g.", \
        "and colleagues" instead of "et al.", "Doktor" instead of "Dr.", "plus or minus" instead of "±"). \
        Introduce an acronym once in full, then use it as it is normally spoken.
        - Do not reproduce formulas, equations, variable names, code, URLs, DOIs, citation markers \
        such as [12] or (Smith et al., 2019), footnote numbers, or references to figures and tables \
        such as "see Fig. 3". Instead, explain in plain words what a formula expresses or what a figure \
        or table shows, including its key values.
        - Avoid parentheses, slashes and dashes used as brackets; fold that information into the \
        sentence. Prefer clear sentences of moderate length.

        Between headings, write complete, natural, flowing prose suitable for narration: no bullet \
        points, no tables, no other markdown formatting. Never write about the sectioning or headings \
        themselves — no meta-commentary, no preamble, no closing remarks, just the headings and the \
        narration text. Write in the same language as the source text, regardless of the language of \
        this instruction.
        """,
        """
        You are a precise summarization assistant preparing narration text for an audiobook. \
        Condense the given text while preserving as much fine-grained detail, as many named facts, \
        figures, numbers, and nuances as possible — omit only redundancy, repetition, and purely \
        stylistic padding. Do not produce a short abstract; produce a denser but still comprehensive \
        retelling that keeps the original's specifics intact wherever feasible.

        As you write, insert a heading — exactly "## " followed by a short descriptive title, alone \
        on its own line — at major meaningful topic transitions or significant narrative shifts. \
        This is how the resulting audiobook's chapter navigation is built, so use headings purposefully \
        for thematic sections, never for minor sub-points or micro-sections. Between headings, write \
        complete, natural, flowing prose suitable for text-to-speech narration: no bullet points, no other \
        markdown formatting. Never write about the sectioning or headings themselves — no meta-commentary, \
        no preamble, no closing remarks, just the headings and the narration text. Write in the same \
        language as the source text below, regardless of the language of this instruction.
        """,
        """
        You are a precise summarization assistant preparing narration text for an audiobook. \
        Condense the given text while preserving as much fine-grained detail, as many named facts, \
        figures, numbers, and nuances as possible — omit only redundancy, repetition, and purely \
        stylistic padding. Do not produce a short abstract; produce a denser but still comprehensive \
        retelling that keeps the original's specifics intact wherever feasible.

        Structure your output into chapters for the audiobook's navigation. Start with a heading, and \
        begin a new heading wherever the source moves on to a new major section or topic — for a paper \
        or report that typically means one heading per main section (for example introduction, \
        background, method, results, discussion). Each chapter should cover a coherent topic; avoid both \
        one giant chapter and tiny micro-chapters. A heading is exactly "## " followed by a short \
        descriptive title, alone on its own line.

        Between headings, write complete, natural, flowing prose suitable for text-to-speech narration: \
        no bullet points, no tables, no other markdown formatting. Never write about the sectioning or \
        headings themselves — no meta-commentary, no preamble, no closing remarks, just the headings and \
        the narration text. Write in the same language as the source text, regardless of the language \
        of this instruction.
        """,
    ]

    /// Image/figure description prompt. Same listening rules as the
    /// summary prompt (numbers as words, no symbols), since the description
    /// is spliced into narrated text.
    static let defaultVisionPrompt = """
    This image comes from a page of a book or document and will be described to a listener of the \
    audiobook version, at exactly the place where it appears in the text. {{caption}}
    Describe what the image shows in two to four flowing sentences of plain prose: its type (photo, \
    micrograph, schematic drawing, diagram, chart, table), the structures or elements it shows, their \
    arrangement, and the key values, labels or trends — enough that the listener can picture it and \
    follow the surrounding text. Start directly with the content; never open with phrases like \
    "The image shows", "The image displays" or "Das Bild zeigt". Do not mention colors unless they \
    carry meaning. Write numbers, units and symbols as spoken words. Write the description in \
    {{language}}, the language of the book. If the image is purely decorative — a logo, icon, \
    ornament, background, or just a short heading or label without further content — answer with \
    exactly: SKIP
    """

    /// Shorter variant for summary mode: the summarizer gets this as one
    /// more paragraph and decides itself whether and how to use it.
    static let defaultVisionPromptShort = """
    This image comes from a page of a book or document. {{caption}}
    In one or two plain sentences, state what it shows and its single most important point. Start \
    directly with the content, without phrases like "The image shows". Write numbers and symbols as \
    spoken words. Write in {{language}}, the language of the book. If the image is purely \
    decorative — a logo, icon, ornament, background, or just a short heading or label — answer \
    with exactly: SKIP
    """

    static let defaultUserPromptTemplate = """
    Book/document title: {{title}}

    Text to condense:
    {{text}}
    """
}

struct DependencyPathOverrides: Codable, Sendable, Equatable {
    var ffmpegPath: String = ""
    var bridgePythonPath: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case ffmpegPath, bridgePythonPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ffmpegPath = try container.decodeIfPresent(String.self, forKey: .ffmpegPath) ?? ""
        bridgePythonPath = try container.decodeIfPresent(String.self, forKey: .bridgePythonPath) ?? ""
    }
}

/// Per-document-type tuning of the two knobs `DocumentType` cares about.
/// Editable in Settings so the defaults picked at design time (see
/// `AppSettings.paperTuning` etc.) are a starting point, not a ceiling —
/// e.g. lowering the paper budget after seeing how a real paper's call
/// turned out at the default size.
struct DocumentTypeTuning: Codable, Sendable, Equatable {
    var minimumChapterCharacters: Int
    var summarizationChunkCharacterBudget: Int

    private enum CodingKeys: String, CodingKey {
        case minimumChapterCharacters, summarizationChunkCharacterBudget
    }

    init(minimumChapterCharacters: Int, summarizationChunkCharacterBudget: Int) {
        self.minimumChapterCharacters = minimumChapterCharacters
        self.summarizationChunkCharacterBudget = summarizationChunkCharacterBudget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minimumChapterCharacters = try container.decodeIfPresent(Int.self, forKey: .minimumChapterCharacters) ?? 900
        summarizationChunkCharacterBudget = try container.decodeIfPresent(Int.self, forKey: .summarizationChunkCharacterBudget) ?? 70000
    }
}

/// Governs two knobs that genuinely differ between document shapes:
/// how aggressively tiny fragments get merged into a neighboring chapter,
/// and how large a summarization batch should be allowed to grow (which in
/// turn determines roughly how many LLM passes a whole document costs).
/// `.general` deliberately defers to the manual sliders in Settings — it's
/// today's behavior, unchanged. Picking a specific type overrides just those
/// two values with a tuned default; everything else (extraction, outline
/// parsing, front-matter trimming) stays identical across types, since that
/// side of the pipeline is already driven by file format, not document type.
enum DocumentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case general
    case book
    case paper
    case report

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "Allgemein"
        case .book: return "Buch"
        case .paper: return "Paper"
        case .report: return "Report"
        }
    }

    var explanation: String {
        switch self {
        case .general:
            return "Nutzt die manuellen Regler unten unverändert."
        case .book:
            return "Größere Mindestkapitelgröße (echte Buchkapitel sind selten winzig). Jedes Original-Kapitel bekommt genau einen Zusammenfassungs-Aufruf (bei sehr langen Kapiteln notfalls mehrere) — nie mehrere Kapitel in einem Aufruf gemischt, damit der Buch-Kapiteltitel als Überschrift erhalten bleibt."
        case .paper:
            return "Kleinere Mindestkapitelgröße. Mehrere Original-Abschnitte werden gleichmäßig auf möglichst wenige, ähnlich große Aufrufe verteilt (±15% Toleranz) — die KI baut die eigentliche Fein-Gliederung dabei selbst per Zwischenüberschriften."
        case .report:
            return "Mittlere Werte zwischen Buch und Paper — passend für Dokumente mit unregelmäßiger Abschnittsstruktur."
        }
    }
}

/// Controls whether vision-model image/diagram descriptions (spliced into
/// the extracted text at each image's position) survive into narration —
/// independently for plain transcription and for the summarized output.
/// Descriptions are useful in both by default, but a user summarizing a
/// figure-heavy paper might want them only in the full transcript (so the
/// summary stays terse), or only in the summary (so a straight transcript
/// stays a faithful reading of just the body text).
enum ImageDescriptionScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcriptionOnly
    case summaryOnly
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcriptionOnly: return "Nur normales Transkript"
        case .summaryOnly: return "Nur KI-Zusammenfassung"
        case .both: return "Beides"
        }
    }

    var includesTranscriptionMode: Bool { self != .summaryOnly }
    var includesSummaryMode: Bool { self != .transcriptionOnly }
}

struct AppSettings: Codable, Sendable, Equatable {
    var ttsEngine: TTSEngineID = .kokoro
    var kokoroVoice: String = "af_heart"
    var kokoroSpeed: Double = 1.0
    var kokoroModelRepo: String = "mlx-community/Kokoro-82M-bf16"

    var piperVoice: String = "de_DE-thorsten-medium"
    var piperSpeed: Double = 1.0
    var kokoroGermanVoice: String = "martin"
    var kokoroGermanSpeed: Double = 1.0
    var kokoroThorstenSpeed: Double = 1.0
    var supertonicVoice: String = "M1"
    var supertonicSpeed: Double = 1.0
    var supertonicSteps: Int = 8
    var supertonicChunkCharacters: Int = 250
    var supertonicPauseSeconds: Double = 0.4
    /// Number of chapters synthesized in parallel (1...4). 2 gives the optimal throughput on Apple Silicon.
    var ttsParallelWorkers: Int = 2

    /// When the extracted text looks German, prefer Piper/Thorsten over the
    /// globally configured default engine (still just a suggestion — always
    /// overridable per book in the review screen).
    var autoSelectEngineByLanguage: Bool = true

    var llmBaseURL: String = "http://localhost:1234/v1"
    var llmAPIKey: String = ""
    var llmModel: String = "qwen3.6-35b-a3b-ud-mlx"
    /// oMLX is the primary backend; LM Studio stays selectable.
    var llmProvider: LLMProviderID = .omlx
    var omlxBaseURL: String = LLMProviderID.omlx.defaultBaseURL
    var omlxAPIKey: String = ""
    var omlxModel: String = ""
    /// Per-provider generation overrides; nil fields = server/model preset.
    /// Temperature 0.4 overrides the model preset by default (user choice
    /// 2026-10-04): at the preset's 0.7 the same paper came back with 4 vs.
    /// 9 chapters between runs; lower is more stable for condensing.
    /// Everything else stays on the server/model preset.
    var omlxGeneration = AppSettings.defaultGenerationOptions
    var lmStudioGeneration = AppSettings.defaultGenerationOptions

    static var defaultGenerationOptions: LLMGenerationOptions {
        var options = LLMGenerationOptions()
        options.temperature = 0.4
        return options
    }
    /// Concurrent summarization calls. oMLX batches concurrent requests
    /// (continuous batching), so 2 noticeably raises throughput for books
    /// with many chapters; LM Studio serializes, so 1 there.
    var omlxParallelRequests: Int = 2
    var lmStudioParallelRequests: Int = 1
    var llmContextLimitTokens: Int = 0 // 0 = automatic (server-reported context window)
    var llmRequestTimeoutSeconds: Double = 900
    var llmConnectionTimeoutSeconds: Double = 5
    var llmVisionTimeoutSeconds: Double = 120
    var llmVisionThinkingMode: LLMThinkingMode = .off
    /// Sends a corrected value when the server preset is clearly a typo
    /// (currently: oMLX `top_p` between 1 and 100, e.g. 95 → 0.95).
    var correctImplausibleServerPresets: Bool = true
    var llmVisionModelOverride: String = ""
    /// Automatically starts oMLX background server if not running before vision/summary passes.
    var autoStartOMLX: Bool = false
    /// Automatically stops oMLX background server after vision/summary passes to free unified memory before TTS synthesis.
    var autoUnloadOMLXAfterPass: Bool = false

    var activeLLMBaseURL: String { llmProvider == .omlx ? omlxBaseURL : llmBaseURL }
    var activeLLMAPIKey: String { llmProvider == .omlx ? omlxAPIKey : llmAPIKey }
    var activeLLMModel: String {
        get { llmProvider == .omlx ? omlxModel : llmModel }
        set { if llmProvider == .omlx { omlxModel = newValue } else { llmModel = newValue } }
    }
    var activeGenerationOptions: LLMGenerationOptions {
        get { llmProvider == .omlx ? omlxGeneration : lmStudioGeneration }
        set { if llmProvider == .omlx { omlxGeneration = newValue } else { lmStudioGeneration = newValue } }
    }
    var activeParallelRequests: Int { max(1, llmProvider == .omlx ? omlxParallelRequests : lmStudioParallelRequests) }

    func defaultVoice(for engine: TTSEngineID) -> String {
        switch engine {
        case .kokoro: return kokoroVoice
        case .piper: return piperVoice
        case .kokoroGerman: return kokoroGermanVoice
        case .kokoroThorsten: return "thorsten"
        case .supertonic3: return supertonicVoice
        }
    }

    func defaultSpeed(for engine: TTSEngineID) -> Double {
        switch engine {
        case .kokoro: return kokoroSpeed
        case .piper: return piperSpeed
        case .kokoroGerman: return kokoroGermanSpeed
        case .kokoroThorsten: return kokoroThorstenSpeed
        case .supertonic3: return supertonicSpeed
        }
    }

    /// Character budget per summarization call: the per-type setting (or manual override),
    /// capped so input + output reserve fit into the model's context window
    /// (manual limit, else what the server reports). The output reserve
    /// mirrors `LLMClient.automaticMaxTokens`.
    func effectiveSummarizationBudget(for type: DocumentType, override: Int? = nil, contextWindow: Int? = nil) -> Int {
        let configured = override ?? summarizationChunkCharacterBudget(for: type)
        let window = llmContextLimitTokens > 0 ? llmContextLimitTokens : (contextWindow ?? 0)
        guard window > 0 else { return configured }
        let options = activeGenerationOptions
        let thinkingReserve = options.thinkingMode == .off ? 0 : (options.effectiveThinkingBudget ?? 16384)
        // input + 0.6*input (summary) + thinking + prompt overhead <= window
        let inputTokens = max(500, Int(Double(window - thinkingReserve - 1536) / 1.6))
        return min(configured, inputTokens * 3)
    }

    var defaultOutputFormat: OutputFormat = .mp3Chapters
    var mp3Quality: Int = 2
    var aacBitrateKbps: Int = 128
    /// Bitrate of the small per-chapter files kept for the in-app player
    /// and single-chapter regeneration. Mono speech at 64 kbps AAC is
    /// ~29 MB per audio hour instead of ~170 MB as WAV.
    var chapterAudioBitrateKbps: Int = 64
    var loudnessNormalizationEnabled: Bool = true
    var loudnessTargetLUFS: Double = -18
    var loudnessTruePeakDB: Double = -1.5
    var loudnessRangeLU: Double = 11
    var voicePreviewSentenceCount: Int = 2
    var voicePreviewMaxCharacters: Int = 300
    var outputBaseFolderPath: String = AppSettings.defaultOutputBaseFolderPath
    var outputFolderTemplate: OutputFolderTemplate = .titleOnly

    var promptTemplates: PromptTemplates = PromptTemplates()
    var dependencyPathOverrides: DependencyPathOverrides = DependencyPathOverrides()

    var stripRecurringHeadersFooters: Bool = true
    var includeFootnotes: Bool = false

    /// Chapters shorter than this (a stray heading, a leftover fragment of
    /// front matter, an oddly-split sub-section) get folded into a
    /// neighboring chapter instead of standing alone as a few seconds of
    /// narration. Applies to both PDF and EPUB extraction.
    var minimumChapterCharacters: Int = 800
    /// Default target characters per chapter when rebundling for narration (transcription mode).
    var targetChapterCharacters: Int = 12000
    /// Skips sections that are essentially never meant to be read aloud in
    /// an audiobook (References, Bibliography, Acknowledgments,
    /// Supplementary Material) — matched by title. Turn off to keep them as
    /// normal, manually deletable chapters in the review screen instead.
    var excludeBackMatterSections: Bool = true

    /// Target character size for one summarization call. Several chapters
    /// can be bundled into a single call up to roughly this size (see
    /// `SummarizerClient.buildBatches`, ±15% tolerance to avoid a tiny
    /// leftover call); a single chapter bigger than this on its own gets
    /// split at paragraph boundaries into pieces of roughly this size
    /// instead. Default measured against a real 9-page/~59k-character paper
    /// (about 6,600 characters/page once cleaned) — comfortably fits in one
    /// call with margin. Lower it for a smaller/weaker local model or a
    /// tighter context window.
    var summarizationChunkCharacterBudget: Int = 70000

    /// Safety net independent of the model: an AI chapter longer than this
    /// (the model under-structured its answer) is split at paragraph
    /// boundaries into "Titel (Teil k/n)". ~12 000 characters ≈ 13 minutes
    /// of narration. 0 = off.
    var aiChapterMaxCharacters: Int = 12000

    /// How far a summarization batch may exceed the evenly distributed
    /// target size (see `SummarizerClient.buildBatches`), so a small
    /// leftover gets folded into the previous call instead of becoming its
    /// own tiny call. 0.15 = ±15 %.
    var summarizationBatchTolerance: Double = 0.15

    /// Optional pre-pass: detect embedded raster images in a PDF, describe
    /// figures/charts/tables via the same (vision-capable) LLM endpoint, and
    /// splice the description into the extracted text at that position so
    /// the summarizer/narrator can work from it. Off by default — needs a
    /// vision-capable model loaded, costs extra calls, and is unproven on
    /// arbitrary documents.
    var describeImagesWithVisionModel: Bool = true
    /// Below this pixel size (in either dimension) an image is treated as a
    /// decorative element (logo, icon, rule) and skipped rather than sent to
    /// the vision model.
    var minimumImageDimensionForVisionPass: Int = 180
    /// Whether image/diagram descriptions survive into plain transcription,
    /// the AI summary, or both. See `ImageDescriptionScope`.
    var imageDescriptionScope: ImageDescriptionScope = .both
    /// Filters deciding which images are worth describing at all (all
    /// must pass): minimum pixel size (see above), minimum share of the
    /// page area, minimum encoded size and maximum aspect ratio. Logos,
    /// icons, arrows, bullets and decorative rules fall through them.
    var minimumImageAreaPercent: Double = 3
    var minimumImageKilobytes: Int = 8
    var maximumImageAspectRatio: Double = 6
    /// Also treat drawn (vector) diagrams and ruled tables as figures.
    var detectVectorFigures: Bool = true
    /// Drop text that belongs to a figure (labels like "rER", "N*", "a b")
    /// from the narration — it is meaningless read aloud.
    var removeFigureLabelText: Bool = true
    /// Read figure captions ("Abb. 6.8 Apoptose …") aloud.
    var keepFigureCaptions: Bool = true
    /// Drop parentheses that only hold page/figure references ("(S. 403)",
    /// "(▶ Abb. 6.8c)") when narrating — applied at narration time.
    var removeCrossReferences: Bool = true
    /// Concurrent vision requests (oMLX batches them).
    var visionParallelRequests: Int = 2
    /// Word that introduces an inserted description; empty = automatic
    /// by document language ("Abbildung" / "Figure").
    var imageDescriptionLabel: String = ""

    /// Suggested document type for new imports (per-book override lives on
    /// `BookProject.documentType`, changeable in the review screen). See
    /// `DocumentType`.
    var defaultDocumentType: DocumentType = .general

    /// Per-type overrides of `minimumChapterCharacters` /
    /// `summarizationChunkCharacterBudget`, editable in Settings. `.general`
    /// has no entry here — it always uses the two manual settings above
    /// directly. Look these up via `minimumChapterCharacters(for:)` /
    /// `summarizationChunkCharacterBudget(for:)` rather than reading the
    /// fields directly, so `.general` is handled in exactly one place.
    var bookTuning = DocumentTypeTuning(minimumChapterCharacters: 1500, summarizationChunkCharacterBudget: 55000)
    var paperTuning = DocumentTypeTuning(minimumChapterCharacters: 850, summarizationChunkCharacterBudget: 75000)
    var reportTuning = DocumentTypeTuning(minimumChapterCharacters: 900, summarizationChunkCharacterBudget: 70000)

    /// When no table of contents and no heading-heuristic matches produce
    /// chapter boundaries, automatically split the text into roughly equal
    /// segments at paragraph boundaries so the user gets a navigable
    /// structure rather than one monolithic block.
    var autoSplitEnabled: Bool = true
    /// Target character count per auto-split segment (~15 000 characters ≈
    /// 6 printed pages ≈ 10-15 minutes of narration).
    var autoSplitTargetCharacters: Int = 15000

    func minimumChapterCharacters(for type: DocumentType) -> Int {
        switch type {
        case .general: return minimumChapterCharacters
        case .book: return bookTuning.minimumChapterCharacters
        case .paper: return paperTuning.minimumChapterCharacters
        case .report: return reportTuning.minimumChapterCharacters
        }
    }

    func summarizationChunkCharacterBudget(for type: DocumentType) -> Int {
        switch type {
        case .general: return summarizationChunkCharacterBudget
        case .book: return bookTuning.summarizationChunkCharacterBudget
        case .paper: return paperTuning.summarizationChunkCharacterBudget
        case .report: return reportTuning.summarizationChunkCharacterBudget
        }
    }

    static var defaultOutputBaseFolderPath: String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let base = documents?.appendingPathComponent("Audiobooks", isDirectory: true)
        return base?.path ?? NSHomeDirectory() + "/Documents/Audiobooks"
    }

    init() {}

    // MARK: - Resilient decoding
    //
    // `SettingsStore` falls back to `AppSettings()` (wiping every saved
    // setting, not just a new one) if decoding throws at all. The
    // compiler-synthesized decoder throws on any missing key, so every field
    // added to this struct after the user already has a settings.json on
    // disk would otherwise silently reset their whole configuration on next
    // launch. Decoding each field individually with `decodeIfPresent(...) ??
    // <that field's own default>` makes adding a field forward-compatible:
    // an old settings.json just gets the new field's default, nothing else
    // is touched.
    private enum CodingKeys: String, CodingKey {
        case ttsEngine, kokoroVoice, kokoroSpeed, kokoroModelRepo
        case piperVoice, piperSpeed, autoSelectEngineByLanguage
        case kokoroGermanVoice, kokoroGermanSpeed, kokoroThorstenSpeed
        case supertonicVoice, supertonicSpeed, supertonicSteps, supertonicChunkCharacters, supertonicPauseSeconds, ttsParallelWorkers
        case llmBaseURL, llmAPIKey, llmModel, llmProvider
        case omlxBaseURL, omlxAPIKey, omlxModel
        case omlxGeneration, lmStudioGeneration, omlxParallelRequests, lmStudioParallelRequests
        case llmContextLimitTokens, llmRequestTimeoutSeconds, llmConnectionTimeoutSeconds
        case llmVisionTimeoutSeconds, llmVisionThinkingMode, llmVisionModelOverride, correctImplausibleServerPresets
        case defaultOutputFormat, outputBaseFolderPath, outputFolderTemplate
        case mp3Quality, aacBitrateKbps, chapterAudioBitrateKbps, loudnessNormalizationEnabled
        case loudnessTargetLUFS, loudnessTruePeakDB, loudnessRangeLU
        case voicePreviewSentenceCount, voicePreviewMaxCharacters
        case promptTemplates, dependencyPathOverrides
        case stripRecurringHeadersFooters, includeFootnotes
        case minimumChapterCharacters, targetChapterCharacters, excludeBackMatterSections
        case summarizationChunkCharacterBudget, aiChapterMaxCharacters, summarizationBatchTolerance
        case describeImagesWithVisionModel, minimumImageDimensionForVisionPass
        case imageDescriptionScope, defaultDocumentType
        case minimumImageAreaPercent, minimumImageKilobytes, maximumImageAspectRatio, detectVectorFigures
        case removeFigureLabelText, keepFigureCaptions, visionParallelRequests, imageDescriptionLabel, removeCrossReferences
        case bookTuning, paperTuning, reportTuning
        case autoSplitEnabled, autoSplitTargetCharacters
        case autoStartOMLX, autoUnloadOMLXAfterPass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()

        ttsEngine = try container.decodeIfPresent(TTSEngineID.self, forKey: .ttsEngine) ?? d.ttsEngine
        kokoroVoice = try container.decodeIfPresent(String.self, forKey: .kokoroVoice) ?? d.kokoroVoice
        kokoroSpeed = try container.decodeIfPresent(Double.self, forKey: .kokoroSpeed) ?? d.kokoroSpeed
        kokoroModelRepo = try container.decodeIfPresent(String.self, forKey: .kokoroModelRepo) ?? d.kokoroModelRepo

        piperVoice = try container.decodeIfPresent(String.self, forKey: .piperVoice) ?? d.piperVoice
        piperSpeed = try container.decodeIfPresent(Double.self, forKey: .piperSpeed) ?? d.piperSpeed
        kokoroGermanVoice = try container.decodeIfPresent(String.self, forKey: .kokoroGermanVoice) ?? d.kokoroGermanVoice
        kokoroGermanSpeed = try container.decodeIfPresent(Double.self, forKey: .kokoroGermanSpeed) ?? d.kokoroGermanSpeed
        kokoroThorstenSpeed = try container.decodeIfPresent(Double.self, forKey: .kokoroThorstenSpeed) ?? d.kokoroThorstenSpeed
        supertonicVoice = try container.decodeIfPresent(String.self, forKey: .supertonicVoice) ?? d.supertonicVoice
        supertonicSpeed = try container.decodeIfPresent(Double.self, forKey: .supertonicSpeed) ?? d.supertonicSpeed
        supertonicSteps = try container.decodeIfPresent(Int.self, forKey: .supertonicSteps) ?? d.supertonicSteps
        supertonicChunkCharacters = try container.decodeIfPresent(Int.self, forKey: .supertonicChunkCharacters) ?? d.supertonicChunkCharacters
        supertonicPauseSeconds = try container.decodeIfPresent(Double.self, forKey: .supertonicPauseSeconds) ?? d.supertonicPauseSeconds
        ttsParallelWorkers = try container.decodeIfPresent(Int.self, forKey: .ttsParallelWorkers) ?? d.ttsParallelWorkers

        autoSelectEngineByLanguage = try container.decodeIfPresent(Bool.self, forKey: .autoSelectEngineByLanguage) ?? d.autoSelectEngineByLanguage

        llmBaseURL = try container.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? d.llmBaseURL
        llmAPIKey = try container.decodeIfPresent(String.self, forKey: .llmAPIKey) ?? d.llmAPIKey
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? d.llmModel
        llmProvider = try container.decodeIfPresent(LLMProviderID.self, forKey: .llmProvider) ?? d.llmProvider
        omlxBaseURL = try container.decodeIfPresent(String.self, forKey: .omlxBaseURL) ?? d.omlxBaseURL
        omlxAPIKey = try container.decodeIfPresent(String.self, forKey: .omlxAPIKey) ?? d.omlxAPIKey
        omlxModel = try container.decodeIfPresent(String.self, forKey: .omlxModel) ?? d.omlxModel
        omlxGeneration = try container.decodeIfPresent(LLMGenerationOptions.self, forKey: .omlxGeneration) ?? d.omlxGeneration
        lmStudioGeneration = try container.decodeIfPresent(LLMGenerationOptions.self, forKey: .lmStudioGeneration) ?? d.lmStudioGeneration
        omlxParallelRequests = try container.decodeIfPresent(Int.self, forKey: .omlxParallelRequests) ?? d.omlxParallelRequests
        lmStudioParallelRequests = try container.decodeIfPresent(Int.self, forKey: .lmStudioParallelRequests) ?? d.lmStudioParallelRequests
        llmContextLimitTokens = try container.decodeIfPresent(Int.self, forKey: .llmContextLimitTokens) ?? d.llmContextLimitTokens
        llmRequestTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .llmRequestTimeoutSeconds) ?? d.llmRequestTimeoutSeconds
        llmConnectionTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .llmConnectionTimeoutSeconds) ?? d.llmConnectionTimeoutSeconds
        llmVisionTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .llmVisionTimeoutSeconds) ?? d.llmVisionTimeoutSeconds
        llmVisionThinkingMode = try container.decodeIfPresent(LLMThinkingMode.self, forKey: .llmVisionThinkingMode) ?? d.llmVisionThinkingMode
        correctImplausibleServerPresets = try container.decodeIfPresent(Bool.self, forKey: .correctImplausibleServerPresets) ?? d.correctImplausibleServerPresets
        llmVisionModelOverride = try container.decodeIfPresent(String.self, forKey: .llmVisionModelOverride) ?? d.llmVisionModelOverride
        autoStartOMLX = try container.decodeIfPresent(Bool.self, forKey: .autoStartOMLX) ?? d.autoStartOMLX
        autoUnloadOMLXAfterPass = try container.decodeIfPresent(Bool.self, forKey: .autoUnloadOMLXAfterPass) ?? d.autoUnloadOMLXAfterPass

        defaultOutputFormat = try container.decodeIfPresent(OutputFormat.self, forKey: .defaultOutputFormat) ?? d.defaultOutputFormat
        mp3Quality = try container.decodeIfPresent(Int.self, forKey: .mp3Quality) ?? d.mp3Quality
        aacBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .aacBitrateKbps) ?? d.aacBitrateKbps
        chapterAudioBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .chapterAudioBitrateKbps) ?? d.chapterAudioBitrateKbps
        loudnessNormalizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .loudnessNormalizationEnabled) ?? d.loudnessNormalizationEnabled
        loudnessTargetLUFS = try container.decodeIfPresent(Double.self, forKey: .loudnessTargetLUFS) ?? d.loudnessTargetLUFS
        loudnessTruePeakDB = try container.decodeIfPresent(Double.self, forKey: .loudnessTruePeakDB) ?? d.loudnessTruePeakDB
        loudnessRangeLU = try container.decodeIfPresent(Double.self, forKey: .loudnessRangeLU) ?? d.loudnessRangeLU
        voicePreviewSentenceCount = try container.decodeIfPresent(Int.self, forKey: .voicePreviewSentenceCount) ?? d.voicePreviewSentenceCount
        voicePreviewMaxCharacters = try container.decodeIfPresent(Int.self, forKey: .voicePreviewMaxCharacters) ?? d.voicePreviewMaxCharacters
        outputBaseFolderPath = try container.decodeIfPresent(String.self, forKey: .outputBaseFolderPath) ?? d.outputBaseFolderPath
        outputFolderTemplate = try container.decodeIfPresent(OutputFolderTemplate.self, forKey: .outputFolderTemplate) ?? d.outputFolderTemplate

        promptTemplates = try container.decodeIfPresent(PromptTemplates.self, forKey: .promptTemplates) ?? d.promptTemplates
        dependencyPathOverrides = try container.decodeIfPresent(DependencyPathOverrides.self, forKey: .dependencyPathOverrides) ?? d.dependencyPathOverrides

        stripRecurringHeadersFooters = try container.decodeIfPresent(Bool.self, forKey: .stripRecurringHeadersFooters) ?? d.stripRecurringHeadersFooters
        includeFootnotes = try container.decodeIfPresent(Bool.self, forKey: .includeFootnotes) ?? d.includeFootnotes

        minimumChapterCharacters = try container.decodeIfPresent(Int.self, forKey: .minimumChapterCharacters) ?? d.minimumChapterCharacters
        targetChapterCharacters = try container.decodeIfPresent(Int.self, forKey: .targetChapterCharacters) ?? d.targetChapterCharacters
        excludeBackMatterSections = try container.decodeIfPresent(Bool.self, forKey: .excludeBackMatterSections) ?? d.excludeBackMatterSections

        summarizationChunkCharacterBudget = try container.decodeIfPresent(Int.self, forKey: .summarizationChunkCharacterBudget) ?? d.summarizationChunkCharacterBudget
        aiChapterMaxCharacters = try container.decodeIfPresent(Int.self, forKey: .aiChapterMaxCharacters) ?? d.aiChapterMaxCharacters
        summarizationBatchTolerance = try container.decodeIfPresent(Double.self, forKey: .summarizationBatchTolerance) ?? d.summarizationBatchTolerance

        describeImagesWithVisionModel = try container.decodeIfPresent(Bool.self, forKey: .describeImagesWithVisionModel) ?? d.describeImagesWithVisionModel
        minimumImageDimensionForVisionPass = try container.decodeIfPresent(Int.self, forKey: .minimumImageDimensionForVisionPass) ?? d.minimumImageDimensionForVisionPass
        imageDescriptionScope = try container.decodeIfPresent(ImageDescriptionScope.self, forKey: .imageDescriptionScope) ?? d.imageDescriptionScope
        minimumImageAreaPercent = try container.decodeIfPresent(Double.self, forKey: .minimumImageAreaPercent) ?? d.minimumImageAreaPercent
        minimumImageKilobytes = try container.decodeIfPresent(Int.self, forKey: .minimumImageKilobytes) ?? d.minimumImageKilobytes
        maximumImageAspectRatio = try container.decodeIfPresent(Double.self, forKey: .maximumImageAspectRatio) ?? d.maximumImageAspectRatio
        detectVectorFigures = try container.decodeIfPresent(Bool.self, forKey: .detectVectorFigures) ?? d.detectVectorFigures
        removeFigureLabelText = try container.decodeIfPresent(Bool.self, forKey: .removeFigureLabelText) ?? d.removeFigureLabelText
        keepFigureCaptions = try container.decodeIfPresent(Bool.self, forKey: .keepFigureCaptions) ?? d.keepFigureCaptions
        removeCrossReferences = try container.decodeIfPresent(Bool.self, forKey: .removeCrossReferences) ?? d.removeCrossReferences
        visionParallelRequests = try container.decodeIfPresent(Int.self, forKey: .visionParallelRequests) ?? d.visionParallelRequests
        imageDescriptionLabel = try container.decodeIfPresent(String.self, forKey: .imageDescriptionLabel) ?? d.imageDescriptionLabel

        defaultDocumentType = try container.decodeIfPresent(DocumentType.self, forKey: .defaultDocumentType) ?? d.defaultDocumentType
        bookTuning = try container.decodeIfPresent(DocumentTypeTuning.self, forKey: .bookTuning) ?? d.bookTuning
        paperTuning = try container.decodeIfPresent(DocumentTypeTuning.self, forKey: .paperTuning) ?? d.paperTuning
        reportTuning = try container.decodeIfPresent(DocumentTypeTuning.self, forKey: .reportTuning) ?? d.reportTuning
        autoSplitEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSplitEnabled) ?? d.autoSplitEnabled
        autoSplitTargetCharacters = try container.decodeIfPresent(Int.self, forKey: .autoSplitTargetCharacters) ?? d.autoSplitTargetCharacters
    }
}
