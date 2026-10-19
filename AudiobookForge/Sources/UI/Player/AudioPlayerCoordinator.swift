import Foundation
import AVFoundation
import Combine

/// Drives in-app playback across a sequence of per-chapter audio files or
/// one packaged M4B/M4A.
///
/// Two playback modes (plan 5.2):
/// - **chapter files**: one `AVAudioPlayer` per chapter (the classic path).
/// - **packaged single file**: one `AVPlayer` over the whole book; chapter
///   jumps are seeks to the chapter's cumulative `audioStartSeconds`, the
///   current chapter is derived from the play head by binary search.
///
/// v3.1: the UI is chapter-centric in BOTH modes — `chapterElapsed` /
/// `chapterDuration` drive the scrubber, `bookElapsed` / `bookDuration`
/// the overall progress. The packaged duration is loaded asynchronously
/// (`asset.load(.duration)`) with the chapter-sum as immediate fallback;
/// before, `item.duration` was read synchronously (still indefinite), the
/// duration stayed 0 and the scrubber pinned to the right (audit finding 1).
@MainActor
final class AudioPlayerCoordinator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var currentChapterIndex: Int = 0
    @Published private(set) var isPlaying: Bool = false {
        didSet { if oldValue != isPlaying { onPlayStateChanged?(isPlaying) } }
    }
    /// Mode-native time: absolute book time (packaged) or chapter time.
    @Published var currentTime: Double = 0
    /// Mode-native duration: whole book (packaged) or current chapter.
    @Published var duration: Double = 0
    /// The sentence currently being narrated, if segment data exists.
    @Published var currentSegmentText: String?
    @Published var currentSegmentIndex: Int?
    /// Playback speed (0.75–2.0×), applies to both modes.
    @Published private(set) var rate: Double = 1.0

    var onChapterFinishedAll: (() -> Void)?
    var onPlayStateChanged: ((Bool) -> Void)?

    private var player: AVAudioPlayer?
    private var chapterURLs: [URL] = []
    private var chapterSegments: [[TTSSegment]] = []
    /// Known chapter durations in narration order (both modes).
    private(set) var chapterDurations: [Double] = []
    private var timer: Timer?

    // MARK: Packaged single-file mode

    private var packagedPlayer: AVPlayer?
    private var packagedChapterStarts: [Double] = []
    private var packagedChapterSegments: [[TTSSegment]] = []
    private var periodicTimeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationTask: Task<Void, Never>?

    var isPackagedMode: Bool { packagedPlayer != nil }
    var hasSource: Bool { packagedPlayer != nil || !chapterURLs.isEmpty }
    var chapterCount: Int { isPackagedMode ? packagedChapterStarts.count : chapterURLs.count }

    var currentChapterSegments: [TTSSegment] {
        let source = isPackagedMode ? packagedChapterSegments : chapterSegments
        return source.indices.contains(currentChapterIndex) ? source[currentChapterIndex] : []
    }

    // MARK: Chapter-centric timeline

    private var currentChapterStart: Double {
        if isPackagedMode {
            return packagedChapterStarts.indices.contains(currentChapterIndex) ? packagedChapterStarts[currentChapterIndex] : 0
        }
        return chapterDurations.prefix(currentChapterIndex).reduce(0, +)
    }

    /// Time inside the current chapter (read-along, scrubber).
    var currentChapterRelativeTime: Double {
        isPackagedMode ? max(0, currentTime - currentChapterStart) : currentTime
    }

    var chapterElapsed: Double { currentChapterRelativeTime }

    var chapterDuration: Double {
        if isPackagedMode {
            let next = packagedChapterStarts.indices.contains(currentChapterIndex + 1)
                ? packagedChapterStarts[currentChapterIndex + 1]
                : bookDuration
            return max(0, next - currentChapterStart)
        }
        return duration > 0 ? duration : (chapterDurations.indices.contains(currentChapterIndex) ? chapterDurations[currentChapterIndex] : 0)
    }

    var bookDuration: Double {
        if isPackagedMode, duration > 0 { return duration }
        let sum = chapterDurations.reduce(0, +)
        return sum > 0 ? sum : duration
    }

    var bookElapsed: Double {
        isPackagedMode ? currentTime : currentChapterStart + currentTime
    }

    // MARK: Loading

    func load(chapterURLs: [URL], segments: [[TTSSegment]] = [], chapterDurations: [Double] = [],
              startingAt index: Int = 0, autoplay: Bool = true) {
        tearDownPackagedPlayback()
        self.chapterURLs = chapterURLs
        self.chapterSegments = segments
        self.chapterDurations = chapterDurations.count == chapterURLs.count ? chapterDurations : chapterURLs.map { _ in 0 }
        prepareChapter(at: index, autoplay: autoplay)
    }

    func reload(chapterURLs: [URL], segments: [[TTSSegment]], chapterDurations: [Double] = []) {
        let index = currentChapterIndex
        let time = currentTime
        let shouldKeepPlaying = isPlaying
        load(chapterURLs: chapterURLs, segments: segments, chapterDurations: chapterDurations, startingAt: index, autoplay: shouldKeepPlaying)
        seek(to: min(time, duration))
    }

    func loadPackaged(url: URL, chapters: [Chapter], startAtChapter index: Int = 0, resumeAtAbsoluteTime absoluteTime: Double? = nil) {
        stopTimer()
        tearDownPackagedPlayback()
        player = nil
        chapterURLs = []
        chapterSegments = []
        let sorted = chapters.sorted { $0.order < $1.order }
        packagedChapterStarts = sorted.map { $0.audioStartSeconds ?? 0 }
        packagedChapterSegments = sorted.map { $0.audioSegments ?? [] }
        chapterDurations = sorted.map { $0.audioDurationSeconds ?? 0 }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        packagedPlayer = newPlayer
        currentSegmentText = nil
        currentSegmentIndex = nil
        isPlaying = false
        // Immediate fallback so the scrubber is usable before AVFoundation
        // has parsed the file: last chapter start + its duration.
        let fallback = (packagedChapterStarts.last ?? 0) + (chapterDurations.last ?? 0)
        duration = max(fallback, chapterDurations.reduce(0, +))
        currentChapterIndex = min(max(index, 0), max(sorted.count - 1, 0))
        currentTime = absoluteTime ?? (packagedChapterStarts.indices.contains(currentChapterIndex) ? packagedChapterStarts[currentChapterIndex] : 0)

        periodicTimeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.packagedPlayer != nil, self.isPlaying else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                self.updatePackagedChapter(forAbsoluteTime: seconds)
                self.updateCurrentSegment()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.packagedPlayer != nil else { return }
                self.isPlaying = false
                self.onChapterFinishedAll?()
            }
        }

        let startTime = currentTime
        if startTime > 0 {
            newPlayer.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updatePackagedChapter(forAbsoluteTime: startTime)
        updateCurrentSegment()

        let asset = item.asset
        durationTask = Task { [weak self] in
            guard let loaded = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(loaded)
            guard seconds.isFinite, seconds > 0 else { return }
            guard let self, self.packagedPlayer === newPlayer else { return }
            self.duration = seconds
        }
    }

    // MARK: Transport

    func playChapter(at index: Int) {
        if isPackagedMode {
            guard packagedChapterStarts.indices.contains(index) else { return }
            currentChapterIndex = index
            seek(to: packagedChapterStarts[index])
            if !isPlaying { play() }
            return
        }
        prepareChapter(at: index, autoplay: true)
    }

    private func prepareChapter(at index: Int, autoplay: Bool) {
        guard chapterURLs.indices.contains(index) else { return }
        stopTimer()
        currentChapterIndex = index
        currentSegmentText = nil
        currentSegmentIndex = nil
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: chapterURLs[index])
            newPlayer.delegate = self
            newPlayer.enableRate = true
            newPlayer.rate = Float(rate)
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            if chapterDurations.indices.contains(index), newPlayer.duration > 0 {
                chapterDurations[index] = newPlayer.duration
            }
            currentTime = 0
            if autoplay { play() } else { isPlaying = false }
        } catch {
            player = nil
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        if let packagedPlayer {
            packagedPlayer.rate = Float(rate)
            isPlaying = true
            return
        }
        guard let player else { return }
        player.play()
        player.rate = Float(rate)
        isPlaying = true
        startTimer()
    }

    func pause() {
        packagedPlayer?.pause()
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        pause()
        tearDownPackagedPlayback()
        player = nil
        chapterURLs = []
        chapterSegments = []
        chapterDurations = []
        currentTime = 0
        duration = 0
        currentChapterIndex = 0
        currentSegmentText = nil
        currentSegmentIndex = nil
    }

    /// Mode-native seek: book time (packaged) or chapter time.
    func seek(to time: Double) {
        if let packagedPlayer {
            let clamped = max(0, duration > 0 ? min(time, duration) : time)
            packagedPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = clamped
            updatePackagedChapter(forAbsoluteTime: clamped)
            updateCurrentSegment()
            return
        }
        let clamped = max(0, duration > 0 ? min(time, duration) : time)
        player?.currentTime = clamped
        currentTime = clamped
        updateCurrentSegment()
    }

    /// Seek inside the current chapter (scrubber, read-along tap).
    func seekInChapter(to chapterTime: Double) {
        seek(to: isPackagedMode ? currentChapterStart + chapterTime : chapterTime)
    }

    /// Jump to a chapter + offset (read-along sentence in any chapter).
    func seek(chapter index: Int, to chapterTime: Double) {
        if index != currentChapterIndex {
            if isPackagedMode {
                guard packagedChapterStarts.indices.contains(index) else { return }
                currentChapterIndex = index
            } else {
                prepareChapter(at: index, autoplay: isPlaying)
            }
        }
        seekInChapter(to: chapterTime)
    }

    /// ±seconds, crossing chapter boundaries in chapter-file mode.
    func skip(by seconds: Double) {
        if isPackagedMode {
            seek(to: currentTime + seconds)
            return
        }
        let target = currentTime + seconds
        if target < 0, currentChapterIndex > 0 {
            let previous = currentChapterIndex - 1
            let wasPlaying = isPlaying
            prepareChapter(at: previous, autoplay: wasPlaying)
            seek(to: max(0, duration + target))
        } else if target > duration, chapterURLs.indices.contains(currentChapterIndex + 1) {
            let wasPlaying = isPlaying
            prepareChapter(at: currentChapterIndex + 1, autoplay: wasPlaying)
            seek(to: min(target - (chapterDurations.indices.contains(currentChapterIndex - 1) ? chapterDurations[currentChapterIndex - 1] : 0), duration))
        } else {
            seek(to: target)
        }
    }

    func setRate(_ newRate: Double) {
        rate = min(max(newRate, 0.75), 2.0)
        if let packagedPlayer, isPlaying {
            packagedPlayer.rate = Float(rate)
        }
        if let player, player.isPlaying {
            player.rate = Float(rate)
        }
    }

    func nextChapter() {
        let next = currentChapterIndex + 1
        guard next < chapterCount else { return }
        playChapter(at: next)
    }

    /// Previous chapter — or back to the chapter start when more than
    /// 3 s in (media-player convention).
    func previousChapter() {
        if chapterElapsed > 3 {
            seekInChapter(to: 0)
            return
        }
        let previous = currentChapterIndex - 1
        guard previous >= 0 else { seekInChapter(to: 0); return }
        playChapter(at: previous)
    }

    // MARK: Internals

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, self.packagedPlayer == nil else { return }
                self.currentTime = player.currentTime
                self.updateCurrentSegment()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateCurrentSegment() {
        let segments = currentChapterSegments
        guard !segments.isEmpty else {
            if currentSegmentText != nil { currentSegmentText = nil }
            if currentSegmentIndex != nil { currentSegmentIndex = nil }
            return
        }
        let time = currentChapterRelativeTime
        if let idx = currentSegmentIndex,
           let current = segments.first(where: { $0.index == idx }),
           time >= current.startSeconds && time < current.startSeconds + current.durationSeconds {
            return
        }
        var low = 0
        var high = segments.count - 1
        var match: TTSSegment?
        while low <= high {
            let mid = (low + high) / 2
            let seg = segments[mid]
            if time < seg.startSeconds {
                high = mid - 1
            } else if time >= seg.startSeconds + seg.durationSeconds {
                low = mid + 1
            } else {
                match = seg
                break
            }
        }
        if match == nil, high >= 0, high < segments.count {
            let candidate = segments[high]
            if time >= candidate.startSeconds { match = candidate }
        }
        if currentSegmentIndex != match?.index { currentSegmentIndex = match?.index }
        if currentSegmentText != match?.text { currentSegmentText = match?.text }
    }

    /// Chapter containing `absoluteTime`, by binary search over the
    /// cumulative chapter starts.
    func chapterIndex(forAbsoluteTime absoluteTime: Double) -> Int {
        var low = 0
        var high = packagedChapterStarts.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if packagedChapterStarts[mid] <= absoluteTime {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    private func updatePackagedChapter(forAbsoluteTime absoluteTime: Double) {
        guard !packagedChapterStarts.isEmpty else { return }
        let index = chapterIndex(forAbsoluteTime: absoluteTime)
        if index != currentChapterIndex {
            currentChapterIndex = index
        }
    }

    private func tearDownPackagedPlayback() {
        durationTask?.cancel()
        durationTask = nil
        if let periodicTimeObserver, let packagedPlayer {
            packagedPlayer.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        packagedPlayer?.pause()
        packagedPlayer = nil
        packagedChapterStarts = []
        packagedChapterSegments = []
        duration = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { self.handleChapterFinished() }
    }

    private func handleChapterFinished() {
        if chapterURLs.indices.contains(currentChapterIndex + 1) {
            prepareChapter(at: currentChapterIndex + 1, autoplay: true)
        } else {
            isPlaying = false
            stopTimer()
            onChapterFinishedAll?()
        }
    }
}
