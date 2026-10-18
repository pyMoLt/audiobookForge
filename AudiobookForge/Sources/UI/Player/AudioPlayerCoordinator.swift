import Foundation
import AVFoundation
import Combine

/// Drives in-app playback across a sequence of per-chapter audio files.
/// Kept separate from `PlayerView` so AVAudioPlayerDelegate (which requires
/// NSObject) doesn't have to live on the view itself.
final class AudioPlayerCoordinator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var currentChapterIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// The sentence currently being narrated, if segment data is available
    /// for this chapter — nil (never an error) whenever it isn't, e.g. for
    /// engines/runs that couldn't produce sentence timing.
    @Published var currentSegmentText: String?

    private var player: AVAudioPlayer?
    private var chapterURLs: [URL] = []
    private var chapterSegments: [[TTSSegment]] = []
    private var timer: Timer?
    var onChapterFinishedAll: (() -> Void)?

    /// Segment list for the chapter currently loaded, if any — used by the
    /// read-along view to render the full text with the active sentence
    /// highlighted. Empty (not an error) when the engine/run has no segment
    /// data for this chapter.
    var currentChapterSegments: [TTSSegment] {
        chapterSegments.indices.contains(currentChapterIndex) ? chapterSegments[currentChapterIndex] : []
    }

    func load(chapterURLs: [URL], segments: [[TTSSegment]] = [], startingAt index: Int = 0) {
        self.chapterURLs = chapterURLs
        self.chapterSegments = segments
        playChapter(at: index)
    }

    func reload(chapterURLs: [URL], segments: [[TTSSegment]]) {
        let index = currentChapterIndex
        let time = currentTime
        let shouldKeepPlaying = isPlaying
        load(chapterURLs: chapterURLs, segments: segments, startingAt: index)
        seek(to: min(time, duration))
        if !shouldKeepPlaying { pause() }
    }

    func playChapter(at index: Int) {
        guard chapterURLs.indices.contains(index) else { return }
        stopTimer()
        currentChapterIndex = index
        currentSegmentText = nil
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: chapterURLs[index])
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            currentTime = 0
            play()
        } catch {
            player = nil
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        player?.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
    }

    func nextChapter() {
        if chapterURLs.indices.contains(currentChapterIndex + 1) {
            playChapter(at: currentChapterIndex + 1)
        }
    }

    func previousChapter() {
        if chapterURLs.indices.contains(currentChapterIndex - 1) {
            playChapter(at: currentChapterIndex - 1)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.updateCurrentSegmentText()
            }
        }
    }

    private func updateCurrentSegmentText() {
        guard chapterSegments.indices.contains(currentChapterIndex) else {
            currentSegmentText = nil
            return
        }
        let segments = chapterSegments[currentChapterIndex]
        let match = segments.first { currentTime >= $0.startSeconds && currentTime < $0.startSeconds + $0.durationSeconds }
        currentSegmentText = match?.text
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if chapterURLs.indices.contains(currentChapterIndex + 1) {
            playChapter(at: currentChapterIndex + 1)
        } else {
            isPlaying = false
            stopTimer()
            onChapterFinishedAll?()
        }
    }
}
