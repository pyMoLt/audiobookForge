import AVFoundation

/// Memory-only voice previews (plan 8.3): synthesizes a short sample with
/// the real engine, decodes it into an in-memory `AVAudioPCMBuffer`, and
/// caches it (NSCache) so replaying a voice is instant. No preview files
/// are left behind — the transient file the engines need is deleted before
/// this returns (TMPDIR is clean afterwards by construction).
///
/// Playback happens in `VoicePreviewPlayer` via AVAudioEngine, directly
/// from the cached buffer.
actor VoicePreviewService {
    static let shared = VoicePreviewService()

    struct Request: Hashable, Sendable {
        let voiceID: VoiceID
        let speed: Double
        let text: String
    }

    /// AVAudioPCMBuffer is not Sendable; previews are only ever consumed
    /// on the main actor (the player), so the wrapper is safe.
    final class PreviewBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private let cache = NSCache<NSString, PreviewBuffer>()
    private let cacheCountLimit: Int
    private let cacheTotalCostBytes: Int
    /// Test hook: counts engine syntheses when set.
    nonisolated(unsafe) static var synthesisCountOverride: (() -> Void)?

    init(cacheCountLimit: Int = 12, cacheTotalCostBytes: Int = 40 * 1024 * 1024) {
        self.cacheCountLimit = cacheCountLimit
        self.cacheTotalCostBytes = cacheTotalCostBytes
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = cacheTotalCostBytes
    }

    private func cacheKey(_ request: Request) -> NSString {
        "\(request.voiceID.engine.rawValue):\(request.voiceID.voice):\(Int(request.speed * 100)):\(request.text.hashValue)" as NSString
    }

    func cachedBuffer(for request: Request) -> PreviewBuffer? {
        cache.object(forKey: cacheKey(request))
    }

    /// Synthesizes (or replays from cache) the sample for a voice.
    /// Throws `TTSEngineError.notReady` when the voice isn't set up.
    func buffer(for request: Request, settings: AppSettings) async throws -> PreviewBuffer {
        let key = cacheKey(request)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let engine = TTSEngineFactory.engine(for: request.voiceID.engine, settings: settings)
        guard await engine.isReady(voice: request.voiceID.voice) else {
            throw TTSEngineError.notReady(L("Stimme ist nicht eingerichtet — siehe Einstellungen → Engines & Downloads."))
        }

        // Transient file: the engines encode through ffmpeg, which needs a
        // target URL. Deleted before this returns, so no preview artifact
        // survives; the cache holds the decoded PCM.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookForge-preview-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try await engine.synthesize(
            text: request.text,
            voice: request.voiceID.voice,
            speed: request.speed,
            outputURL: outputURL,
            onProgress: { _ in }
        )

        let audioFile = try AVAudioFile(forReading: result.audioFileURL)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw TTSEngineError.processFailed("Vorschau konnte nicht in den Arbeitsspeicher geladen werden.")
        }
        try audioFile.read(into: buffer)
        Self.synthesisCountOverride?()

        let preview = PreviewBuffer(buffer: buffer)
        cache.setObject(preview, forKey: key, cost: memoryCost(buffer))
        return preview
    }

    /// Empties the cache (called when the gallery closes and on memory
    /// pressure hooks).
    func clearCache() {
        cache.removeAllObjects()
    }

    private func memoryCost(_ buffer: AVAudioPCMBuffer) -> Int {
        Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    }}
