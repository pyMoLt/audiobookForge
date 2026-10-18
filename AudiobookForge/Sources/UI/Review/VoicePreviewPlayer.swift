import Foundation
import AVFoundation

/// Synthesizes and plays a short one- or two-sentence clip so the user can
/// hear a voice/speed/engine combination before committing to running the
/// whole book through it.
@MainActor
final class VoicePreviewPlayer: ObservableObject {
    @Published var isGenerating = false
    @Published var isPlaying = false
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var previewFileURL: URL?

    func preview(text: String, engineID: TTSEngineID, voice: String, speed: Double, settings: AppSettings) {
        task?.cancel()
        errorMessage = nil
        isGenerating = true
        removePreviewFile()

        let sampleText = String(SentenceSplitter.split(text)
            .prefix(max(1, settings.voicePreviewSentenceCount))
            .joined(separator: " ")
            .prefix(max(40, settings.voicePreviewMaxCharacters)))
        guard !sampleText.isEmpty else {
            isGenerating = false
            errorMessage = "Kein Text für eine Vorschau gefunden."
            return
        }

        task = Task {
            let engine = TTSEngineFactory.engine(for: engineID, settings: settings)
            guard await engine.isReady(voice: voice) else {
                await MainActor.run {
                    self.isGenerating = false
                    self.errorMessage = "Engine ist nicht eingerichtet — siehe Einstellungen → Diagnose."
                }
                return
            }

            // Small compressed preview clip (same encode path as real
            // chapters — no WAV intermediate, a few dozen KB at most).
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookForge-preview-\(UUID().uuidString).m4a")
            do {
                let result = try await engine.synthesize(text: sampleText, voice: voice, speed: speed, outputURL: outputURL, onProgress: { _ in })
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }
                await MainActor.run {
                    self.isGenerating = false
                    self.previewFileURL = result.audioFileURL
                    self.play(url: result.audioFileURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                await MainActor.run {
                    self.isGenerating = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func play(url: URL) {
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            player = newPlayer
            newPlayer.play()
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        task?.cancel()
        player?.stop()
        isPlaying = false
        isGenerating = false
        removePreviewFile()
    }

    /// Previews are throwaway clips in /tmp — delete them as soon as they
    /// are no longer needed instead of piling up.
    private func removePreviewFile() {
        guard let url = previewFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        previewFileURL = nil
    }
}
