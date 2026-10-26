import Foundation
import AVFoundation

/// Plays short voice previews entirely from memory (plan 8.3): synthesis
/// and caching live in `VoicePreviewService` (NSCache of PCM buffers), and
/// this player feeds the buffer straight into AVAudioEngine — no preview
/// files, instant replay from the cache.
@MainActor
final class VoicePreviewPlayer: ObservableObject {
    @Published var isGenerating = false
    @Published var isPlaying = false
    @Published var errorMessage: String?

    /// The voice of the last requested preview (nil after stop) — the
    /// gallery uses it for its play/stop button state.
    private(set) var currentVoiceID: VoiceID?

    private var task: Task<Void, Never>?
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var engineRunning = false

    private let service: VoicePreviewService

    init(service: VoicePreviewService = .shared) {
        self.service = service
    }

    /// Play/stop toggle for a gallery row: re-clicking the busy voice
    /// stops it, clicking another voice switches immediately.
    func toggle(text: String, engineID: TTSEngineID, voice: String, speed: Double, settings: AppSettings) {
        let requested = VoiceID(engine: engineID, voice: voice)
        if currentVoiceID == requested, isPlaying || isGenerating {
            stop()
            return
        }
        preview(text: text, engineID: engineID, voice: voice, speed: speed, settings: settings)
    }

    func preview(text: String, engineID: TTSEngineID, voice: String, speed: Double, settings: AppSettings) {
        task?.cancel()
        errorMessage = nil
        isGenerating = true
        stopPlayback()
        currentVoiceID = VoiceID(engine: engineID, voice: voice)

        // v4: the bundled sample plays instantly, even before the engine
        // is installed (only for the catalog's own sample text).
        if let sampleURL = VoiceSampleLibrary.url(for: VoiceID(engine: engineID, voice: voice), text: text),
           let file = try? AVAudioFile(forReading: sampleURL),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
           (try? file.read(into: buffer)) != nil {
            isGenerating = false
            play(buffer)
            return
        }

        let sampleText = String(SentenceSplitter.split(text)
            .prefix(max(1, settings.voicePreviewSentenceCount))
            .joined(separator: " ")
            .prefix(max(40, settings.voicePreviewMaxCharacters)))
        guard !sampleText.isEmpty else {
            isGenerating = false
            errorMessage = "Kein Text für eine Vorschau gefunden."
            return
        }

        let request = VoicePreviewService.Request(
            voiceID: VoiceID(engine: engineID, voice: voice),
            speed: speed,
            text: sampleText,
            expression: settings.expression(for: engineID) ?? 0
        )
        task = Task {
            do {
                let preview = try await service.buffer(for: request, settings: settings)
                guard !Task.isCancelled else { return }
                self.isGenerating = false
                self.play(preview.buffer)
            } catch is CancellationError {
                // Re-clicked: the new preview owns the UI state.
            } catch {
                self.isGenerating = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        do {
            if !engineRunning {
                engine.attach(playerNode)
                engineRunning = true
            }
            engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
            playerNode.play()
            isPlaying = true

            // Reset the button when the clip ends.
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000) + 200_000_000)
                guard let self, !Task.isCancelled else { return }
                self.isPlaying = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        task?.cancel()
        stopPlayback()
        isPlaying = false
        isGenerating = false
        currentVoiceID = nil
    }

    private func stopPlayback() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        if engine.isRunning {
            engine.stop()
            engine.reset()
        }
    }
}
