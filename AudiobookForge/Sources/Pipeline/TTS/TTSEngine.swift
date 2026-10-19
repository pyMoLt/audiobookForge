import Foundation

struct TTSVoiceOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String

    /// Names carry a German gender tag ("Heart (US, weiblich)"); translate
    /// just that word so the voice lists follow the app language.
    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
            .replacingOccurrences(of: "weiblich", with: L("weiblich"))
            .replacingOccurrences(of: "männlich", with: L("männlich"))
    }
}

enum TTSProgressEvent: Sendable {
    case modelLoaded
    /// Engine knows up front how many segments it will produce (lets the
    /// progress view show exact per-chapter progress instead of an
    /// audio-length estimate).
    case plannedSegments(Int)
    case segmentDone(index: Int, durationSeconds: Double)
}

/// One sentence-ish unit of narration within a chapter's audio, used for the
/// (best-effort) sentence-accurate playback position. Always optional
/// downstream — a chapter without segment data just shows chapter-level
/// progress instead of a crash or an error.
struct TTSSegment: Codable, Sendable, Equatable {
    let index: Int
    let startSeconds: Double
    let durationSeconds: Double
    let text: String?
}

struct TTSSynthesisResult: Sendable {
    let audioFileURL: URL
    let durationSeconds: Double
    let segmentCount: Int
    var segments: [TTSSegment]? = nil
}

enum TTSEngineError: LocalizedError {
    case notReady(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let reason): return "TTS-Engine ist nicht einsatzbereit: \(reason)"
        case .processFailed(let reason): return "TTS-Erzeugung fehlgeschlagen: \(reason)"
        }
    }
}

/// Narrow, engine-independent interface the pipeline uses to turn text into
/// audio. Kokoro is currently the only implementation, but nothing outside
/// this file (and KokoroEngine.swift) knows that.
protocol TTSEngine: Sendable {
    var id: TTSEngineID { get }
    func availableVoices() -> [TTSVoiceOption]
    func isReady() async -> Bool
    func isReady(voice: String) async -> Bool
    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult
}

extension TTSEngine {
    func isReady(voice: String) async -> Bool { await isReady() }
}

enum TTSEngineFactory {
    /// Test hook: when set, `engine(for:settings:)` returns this instead
    /// of a real engine. Lets pause/resume and pipeline tests run with a
    /// deterministic fake (no bridge, no model downloads).
    nonisolated(unsafe) static var engineOverride: ((TTSEngineID) -> TTSEngine)?

    static func engine(for id: TTSEngineID, settings: AppSettings) -> TTSEngine {
        if let engineOverride {
            return engineOverride(id)
        }
        switch id {
        case .kokoro:
            return KokoroEngine(settings: settings, bridge: BridgeEnvironmentManager.shared)
        case .piper:
            return PiperEngine(settings: settings, environment: PiperEnvironmentManager.shared)
        case .kokoroGerman, .kokoroThorsten:
            return KokoroEngine(settings: settings, bridge: BridgeEnvironmentManager.shared, id: id)
        case .supertonic3:
            return SupertonicEngine(settings: settings, environment: SupertonicEnvironmentManager.shared)
        case .omniVoice:
            return OmniVoiceEngine(settings: settings, environment: OmniVoiceEnvironmentManager.shared)
        case .appleSystem:
            return AppleSpeechEngine(settings: settings)
        }
    }

    static func availableVoices(for id: TTSEngineID) -> [TTSVoiceOption] {
        engine(for: id, settings: AppSettings()).availableVoices()
    }
}
