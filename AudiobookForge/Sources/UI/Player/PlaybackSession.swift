import Foundation
import Observation

/// App-wide playback state (v3.1). Previously the player lived inside
/// `PlayerView` and died with it — switching to the library or settings
/// stopped the book and the ambience. Now one session survives navigation:
/// the sidebar shows a mini player, the shelf can resume, and the ambient
/// scene keeps running.
@MainActor
@Observable
final class PlaybackSession {
    let coordinator = AudioPlayerCoordinator()
    let ambient = AmbientController()

    /// Book currently loaded into the coordinator.
    private(set) var bookID: UUID?
    /// Volume name (or "") when no playable source was found.
    private(set) var missingVolume: String?
    private(set) var isLoading = false

    /// Sleep timer end (nil = off). The ambience burns down with it.
    private(set) var sleepTimerEnd: Date?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var listeningFlush: Task<Void, Never>?

    init() {
        coordinator.onPlayStateChanged = { [weak self] isPlaying in
            guard let self else { return }
            if !isPlaying { self.savePosition() }
            self.ambient.followPlayback(isPlaying: isPlaying)
            self.trackListening(isPlaying: isPlaying)
        }
    }

    /// Listening statistics (v3.2): real time spent listening, per day.
    /// Flushed on pause and once a minute while playing.
    private func trackListening(isPlaying: Bool) {
        if let since = listeningSince {
            ListeningStats.add(Date().timeIntervalSince(since))
            listeningSince = nil
        }
        listeningFlush?.cancel()
        guard isPlaying else { return }
        listeningSince = Date()
        listeningFlush = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let since = self.listeningSince else { return }
                let now = Date()
                ListeningStats.add(now.timeIntervalSince(since))
                self.listeningSince = now
            }
        }
    }

    /// Loads `book` unless it is already the active one. Returns quickly
    /// when the same book is re-opened (no restart, no position jump).
    func open(_ book: BookProject) async {
        if bookID == book.id, missingVolume == nil { return }
        if bookID != nil { savePosition() }
        coordinator.pause()
        bookID = book.id
        missingVolume = nil
        isLoading = true
        defer { isLoading = false }

        let source = await PlaybackSourceResolver.resolve(book: book)
        guard bookID == book.id else { return }
        let saved = PlaybackProgressStore.load(bookID: book.id)
        let sorted = book.sortedChapters
        switch source {
        case .packaged(let url, let chapters):
            if let saved, saved.isAbsolute {
                coordinator.loadPackaged(url: url, chapters: chapters, resumeAtAbsoluteTime: saved.time)
            } else if let saved {
                coordinator.loadPackaged(url: url, chapters: chapters, startAtChapter: saved.chapterIndex)
            } else {
                coordinator.loadPackaged(url: url, chapters: chapters)
            }
        case .chapterFiles(let urls, let segments):
            coordinator.load(chapterURLs: urls, segments: segments, chapterDurations: sorted.map { $0.audioDurationSeconds ?? 0 },
                             startingAt: saved?.chapterIndex ?? 0, autoplay: false)
            if let saved, !saved.isAbsolute {
                coordinator.seek(to: saved.time)
            }
        case .missing(let volumeName):
            missingVolume = volumeName ?? ""
        }
        ambient.restore(for: book)
    }

    /// Forget the loaded source (e.g. after re-assigning the output file).
    func reload(_ book: BookProject) async {
        bookID = nil
        await open(book)
    }

    /// Stop everything (book removed from the library, app quit).
    func close() {
        savePosition()
        coordinator.stop()
        ambient.stop()
        bookID = nil
        missingVolume = nil
        cancelSleepTimer()
    }

    func savePosition() {
        guard let bookID, missingVolume == nil, coordinator.hasSource else { return }
        let saved = PlaybackProgressStore.Saved(
            chapterIndex: coordinator.currentChapterIndex,
            time: coordinator.isPackagedMode ? coordinator.currentTime : coordinator.currentChapterRelativeTime,
            isAbsolute: coordinator.isPackagedMode,
            lastPlayedAt: Date()
        )
        PlaybackProgressStore.save(saved, bookID: bookID)
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes, minutes > 0 else {
            sleepTimerEnd = nil
            ambient.setBurnDown(nil)
            return
        }
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEnd = end
        ambient.setBurnDown(end)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled, let self else { return }
            self.coordinator.pause()
            self.ambient.stop()
            self.sleepTimerEnd = nil
            self.ambient.setBurnDown(nil)
        }
    }

    func cancelSleepTimer() { setSleepTimer(minutes: nil) }
}
