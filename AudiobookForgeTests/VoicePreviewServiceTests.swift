import XCTest
import AVFoundation
@testable import AudiobookForge

/// Plan 8.3 — memory-only voice previews: caching, eviction, no leftover
/// files, error states. Uses a local fake engine that produces a genuine
/// .m4a through the production `ChapterAudioEncoder` (sine PCM — no TTS
/// model involved), so the service's AVAudioFile decode path runs for real.
final class VoicePreviewServiceTests: XCTestCase {
    /// Sine-PCM producer encoded via the real chapter encoder (same path
    /// Piper uses for its raw output).
    private final class SineFakeEngine: TTSEngine, @unchecked Sendable {
        let id: TTSEngineID = .kokoro
        let synthesizeCalls = LockedBox<[String: Int]>([:])
        private let ready: LockedBox<Bool>
        private let settings: AppSettings

        init(ready: Bool = true, settings: AppSettings = AppSettings()) {
            self.ready = LockedBox(ready)
            self.settings = settings
        }

        func setReady(_ value: Bool) { ready.withLock { $0 = value } }

        func availableVoices() -> [TTSVoiceOption] {
            [TTSVoiceOption(id: "fake", displayName: "Fake Stimme")]
        }

        func isReady() async -> Bool { ready.withLock { $0 } }

        func synthesize(
            text: String,
            voice: String,
            speed: Double,
            outputURL: URL,
            onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
        ) async throws -> TTSSynthesisResult {
            synthesizeCalls.withLock { $0[voice, default: 0] += 1 }
            let sampleRate = 22050
            let sampleCount = sampleRate / 5
            var pcm = Data()
            for index in 0..<sampleCount {
                let value = Int16((sin(2 * .pi * 440 * Double(index) / Double(sampleRate)) * 8000).rounded())
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
            }
            let encoder = try ChapterAudioEncoder.start(sampleRate: sampleRate, outputURL: outputURL, settings: settings, stdinPipe: Pipe())
            do {
                try encoder.write(pcm)
                let duration = try await encoder.finish()
                return TTSSynthesisResult(
                    audioFileURL: outputURL,
                    durationSeconds: duration,
                    segmentCount: 1,
                    segments: [TTSSegment(index: 0, startSeconds: 0, durationSeconds: duration, text: text)]
                )
            } catch {
                encoder.abort()
                throw error
            }
        }
    }

    override func tearDown() {
        TTSEngineFactory.engineOverride = nil
        VoicePreviewService.synthesisCountOverride = nil
    }

    private func request(voice: String) -> VoicePreviewService.Request {
        VoicePreviewService.Request(
            voiceID: VoiceID(engine: .kokoro, voice: voice),
            speed: 1.0,
            text: "Kurzer Beispielsatz für die Hörprobe."
        )
    }

    private func tempDirectoryContents() -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.map(\.lastPathComponent))
    }

    func testSecondRequestHitsCacheWithoutNewSynthesis() async throws {
        let engine = SineFakeEngine()
        TTSEngineFactory.engineOverride = { _ in engine }
        let service = VoicePreviewService()
        let settings = AppSettings()

        _ = try await service.buffer(for: request(voice: "a"), settings: settings)
        let callsAfterFirst = engine.synthesizeCalls.withLock { $0 }
        _ = try await service.buffer(for: request(voice: "a"), settings: settings)
        let callsAfterSecond = engine.synthesizeCalls.withLock { $0 }

        XCTAssertEqual(callsAfterSecond["a"], callsAfterFirst["a"], "Cache-Treffer synthetisiert nicht neu")
        let cached = await service.cachedBuffer(for: request(voice: "a"))
        XCTAssertNotNil(cached, "Puffer liegt im Cache")
    }

    func testEvictionReSynthesizes() async throws {
        let engine = SineFakeEngine()
        TTSEngineFactory.engineOverride = { _ in engine }
        let service = VoicePreviewService(cacheCountLimit: 2)
        let settings = AppSettings()

        _ = try await service.buffer(for: request(voice: "a"), settings: settings)
        _ = try await service.buffer(for: request(voice: "b"), settings: settings)
        _ = try await service.buffer(for: request(voice: "c"), settings: settings)

        let evicted = await service.cachedBuffer(for: request(voice: "a"))
        XCTAssertNil(evicted, "Bei 2 Puffer-Plätzen ist die älteste Stimme verdrängt")
        _ = try await service.buffer(for: request(voice: "a"), settings: settings)
        XCTAssertEqual(engine.synthesizeCalls.withLock { $0["a"] }, 2, "Nach Verdrängung wird neu synthetisiert")
    }

    func testNoPreviewFilesLeftBehind() async throws {
        let engine = SineFakeEngine()
        TTSEngineFactory.engineOverride = { _ in engine }
        let service = VoicePreviewService()
        let settings = AppSettings()
        let before = tempDirectoryContents()

        _ = try await service.buffer(for: request(voice: "a"), settings: settings)
        let after = tempDirectoryContents()
        let leftovers = after.subtracting(before)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("AudiobookForge-preview") }, "Keine Vorschaudateien liegen nach der Vorschau herum: \(leftovers)")
    }

    func testClearCacheDropsBuffers() async throws {
        let engine = SineFakeEngine()
        TTSEngineFactory.engineOverride = { _ in engine }
        let service = VoicePreviewService()
        let settings = AppSettings()
        _ = try await service.buffer(for: request(voice: "a"), settings: settings)
        await service.clearCache()
        let cached = await service.cachedBuffer(for: request(voice: "a"))
        XCTAssertNil(cached)
    }

    func testNotReadyEngineThrowsUnderstandableError() async throws {
        let engine = SineFakeEngine(ready: false)
        TTSEngineFactory.engineOverride = { _ in engine }
        let service = VoicePreviewService()

        do {
            _ = try await service.buffer(for: request(voice: "a"), settings: AppSettings())
            XCTFail("Unerwarteter Erfolg")
        } catch let error as TTSEngineError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(error.errorDescription?.contains("nicht eingerichtet") == true)
        }
    }
}
