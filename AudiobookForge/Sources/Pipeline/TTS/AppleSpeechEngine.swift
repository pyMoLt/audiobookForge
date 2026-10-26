import Foundation
import AVFoundation

/// macOS system voices (v3.2) as an engine: the voices installed under
/// System Settings → Accessibility → Spoken Content, including the
/// downloadable Enhanced/Premium ones (e.g. "Anna" for German). No model,
/// no Python — fast, medium quality, always available.
///
/// Same scheme as Piper: one sentence (planned segment) at a time via
/// `AVSpeechSynthesizer.write`, PCM converted to one fixed format and
/// streamed into the chapter encoder, planned pauses written as silence —
/// so every segment carries its exact text and timing (read-along).
struct AppleSpeechEngine: TTSEngine {
    let settings: AppSettings
    var id: TTSEngineID { .appleSystem }

    /// Output format of every chapter written by this engine.
    static let sampleRate: Double = 24_000

    /// "auto" picks the best installed voice for the text's language.
    static let automaticVoice = "auto"

    func availableVoices() -> [TTSVoiceOption] {
        [TTSVoiceOption(id: Self.automaticVoice, displayName: L("Automatisch (beste installierte Stimme)"))]
            + Self.installedVoices().map { TTSVoiceOption(id: $0.identifier, displayName: Self.label(for: $0)) }
    }

    func isReady() async -> Bool { !Self.installedVoices().isEmpty }

    func isReady(voice: String) async -> Bool {
        voice == Self.automaticVoice ? !Self.installedVoices().isEmpty : AVSpeechSynthesisVoice(identifier: voice) != nil
    }

    // MARK: Voices

    /// German, English, French, Spanish and Italian system voices (v4),
    /// best quality first; novelty
    /// voices (Bells, Bubbles …) and Personal Voice are left out.
    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in ["de", "en", "fr", "es", "it"].contains { voice.language.hasPrefix($0) } }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if a.language != b.language { return a.language < b.language }
                return a.name < b.name
            }
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return L("Erweitert")
        default: return L("Standard")
        }
    }

    static func label(for voice: AVSpeechSynthesisVoice) -> String {
        "\(voice.name) (\(voice.language), \(qualityLabel(voice.quality)))"
    }

    /// The best installed voice for a language code ("de", "en-US" …).
    static func bestVoice(forLanguage code: String) -> AVSpeechSynthesisVoice? {
        let base = String(code.prefix(2))
        let candidates = installedVoices().filter { $0.language.hasPrefix(base) }
        // Within the best available quality: the main region first (de-DE,
        // en-US), then the familiar narrators, then the rest.
        let mainRegion = base == "en" ? "en-US" : "\(base)-\(base.uppercased())"
        let preferredNames = ["Anna", "Samantha", "Daniel", "Karen", "Helena", "Markus"]
        return candidates.min { a, b in
            func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int, Int) {
                (-v.quality.rawValue, v.language == mainRegion ? 0 : 1, preferredNames.firstIndex { v.name.hasPrefix($0) } ?? 99)
            }
            return rank(a) < rank(b)
        }
    }

    // MARK: Synthesis

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        outputURL: URL,
        onProgress: @escaping @Sendable (TTSProgressEvent) -> Void
    ) async throws -> TTSSynthesisResult {
        let resolved: AVSpeechSynthesisVoice?
        if voice == Self.automaticVoice || voice.isEmpty {
            resolved = Self.bestVoice(forLanguage: LanguageDetector.detectLanguageCode(sampleText: text) ?? "de")
        } else {
            resolved = AVSpeechSynthesisVoice(identifier: voice)
        }
        guard let systemVoice = resolved else {
            throw TTSEngineError.notReady(L("Keine passende Systemstimme installiert (Systemeinstellungen → Bedienungshilfen → Gesprochene Inhalte)."))
        }

        let plannedSegments = PausePlanner.plan(text)
        let sentences = plannedSegments.map(\.text)
        guard !sentences.isEmpty else { throw TTSEngineError.processFailed("Kein Text zum Vorlesen gefunden.") }
        let pausePlan = PausePlanner.pausePlan(for: plannedSegments, determinismKey: outputURL.path, settings: settings)

        onProgress(.modelLoaded)
        onProgress(.plannedSegments(sentences.count))

        let rate = Int(Self.sampleRate)
        let encoder = try ChapterAudioEncoder.start(sampleRate: rate, outputURL: outputURL, settings: settings, stdinPipe: Pipe())
        func silence(_ milliseconds: Int) -> Data { Data(count: Int(Self.sampleRate * Double(milliseconds) / 1000) * 2) }

        do {
            var segments: [TTSSegment] = []
            var cumulative = 0.0
            if pausePlan.leadInMs > 0 {
                try encoder.write(silence(pausePlan.leadInMs))
                cumulative += Double(pausePlan.leadInMs) / 1000
            }
            for (index, sentence) in sentences.enumerated() {
                try Task.checkCancellation()
                let pcm = try await Self.render(sentence, voice: systemVoice, speed: speed)
                try encoder.write(pcm)
                var duration = Double(pcm.count) / (2 * Self.sampleRate)
                let pauseMs = index < pausePlan.pauseAfterMs.count ? pausePlan.pauseAfterMs[index] : 0
                if pauseMs > 0 {
                    try encoder.write(silence(pauseMs))
                    duration += Double(pauseMs) / 1000
                }
                segments.append(TTSSegment(index: index, startSeconds: cumulative, durationSeconds: duration, text: sentence))
                cumulative += duration
                onProgress(.segmentDone(index: index, durationSeconds: duration))
            }
            if pausePlan.tailMs > 0 { try encoder.write(silence(pausePlan.tailMs)) }
            let total = try await encoder.finish()
            return TTSSynthesisResult(audioFileURL: outputURL, durationSeconds: total, segmentCount: sentences.count, segments: segments)
        } catch {
            encoder.abort()
            throw error
        }
    }

    /// One sentence → 16-bit mono PCM at `sampleRate`.
    private static func render(_ sentence: String, voice: AVSpeechSynthesisVoice, speed: Double) async throws -> Data {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        let base = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, base * Float(speed)))
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

        final class Collector: @unchecked Sendable {
            let synthesizer = AVSpeechSynthesizer()
            var data = Data()
            var converter: AVAudioConverter?
            var finished = false
        }
        let collector = Collector()

        return try await withCheckedThrowingContinuation { continuation in
            collector.synthesizer.write(utterance) { buffer in
                guard !collector.finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    // An empty buffer marks the end of the utterance.
                    collector.finished = true
                    continuation.resume(returning: collector.data)
                    return
                }
                if collector.converter == nil || collector.converter?.inputFormat != pcm.format {
                    collector.converter = AVAudioConverter(from: pcm.format, to: target)
                }
                guard let converter = collector.converter else { return }
                let capacity = AVAudioFrameCount(Double(pcm.frameLength) * sampleRate / pcm.format.sampleRate) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var consumed = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return pcm
                }
                if let channel = out.int16ChannelData, out.frameLength > 0 {
                    collector.data.append(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
                }
            }
        }
    }
}
