import Foundation

/// Re-voicing a book (v4): speak the existing text again with another
/// voice — for summaries (the stored LLM text is reused unless the user
/// asks for a new summary) and for plain narration alike. Image
/// descriptions and the cleaned text live in the chapters and are kept.
///
/// The old narration is replaced only when the new one is complete: the
/// book keeps a `RevoiceBackup`, the packagers stage their output, and a
/// failed or cancelled run puts everything back.
enum Revoicing {
    /// Snapshot + reset for a new run with `engine`/`voice`. Chapter audio
    /// kept in the app's chapter folder is moved aside so the new run can't
    /// overwrite it.
    static func prepare(
        _ book: inout BookProject,
        engine: TTSEngineID,
        voice: String,
        speed: Double,
        resummarize: Bool,
        chapterAudioRoot: URL
    ) {
        if book.revoiceBackup == nil {
            var backupChapters = book.chapters
            let liveDir = chapterAudioRoot.appendingPathComponent(book.id.uuidString, isDirectory: true)
            let asideDir = backupDirectory(bookID: book.id, root: chapterAudioRoot)
            let fm = FileManager.default
            if backupChapters.contains(where: { $0.audioFileURL?.path.hasPrefix(liveDir.path) == true }),
               fm.fileExists(atPath: liveDir.path) {
                try? fm.removeItem(at: asideDir)
                if (try? fm.moveItem(at: liveDir, to: asideDir)) != nil {
                    for i in backupChapters.indices {
                        if let url = backupChapters[i].audioFileURL, url.path.hasPrefix(liveDir.path) {
                            backupChapters[i].audioFileURL = asideDir.appendingPathComponent(url.lastPathComponent)
                        }
                    }
                }
            }
            book.revoiceBackup = RevoiceBackup(engineID: book.engineID, voice: book.voice, speechSpeed: book.speechSpeed,
                                               status: book.status, chapters: backupChapters,
                                               sourceChapters: book.sourceChapters, packagedAudio: book.packagedAudio)
        }
        book.engineID = engine
        book.voice = voice
        book.speechSpeed = speed
        book.packagedAudio = nil
        book.lastErrorMessage = nil
        if resummarize, book.mode == .summary, let source = book.sourceChapters {
            // The summarizer starts again from the pristine document.
            book.chapters = source.map { var chapter = $0; chapter.summarizedText = nil; return chapter }
        }
        for i in book.chapters.indices {
            book.chapters[i].audioStatus = .pending
            book.chapters[i].audioFileURL = nil
            book.chapters[i].audioDurationSeconds = nil
            book.chapters[i].audioStartSeconds = nil
            book.chapters[i].audioSegments = nil
            book.chapters[i].lastError = nil
        }
    }

    static func backupDirectory(bookID: UUID, root: URL) -> URL {
        root.appendingPathComponent("\(bookID.uuidString).revoice-backup", isDirectory: true)
    }

    /// Puts the previous narration back (failed/cancelled run).
    static func restore(_ book: inout BookProject, chapterAudioRoot: URL) {
        guard let backup = book.revoiceBackup else { return }
        let fm = FileManager.default
        let liveDir = chapterAudioRoot.appendingPathComponent(book.id.uuidString, isDirectory: true)
        let asideDir = backupDirectory(bookID: book.id, root: chapterAudioRoot)
        var chapters = backup.chapters
        if fm.fileExists(atPath: asideDir.path) {
            try? fm.removeItem(at: liveDir)
            if (try? fm.moveItem(at: asideDir, to: liveDir)) != nil {
                for i in chapters.indices {
                    if let url = chapters[i].audioFileURL, url.path.hasPrefix(asideDir.path) {
                        chapters[i].audioFileURL = liveDir.appendingPathComponent(url.lastPathComponent)
                    }
                }
            }
        } else {
            // New chapter files of the aborted run are not the book's audio.
            try? fm.removeItem(at: liveDir)
        }
        book.engineID = backup.engineID
        book.voice = backup.voice
        book.speechSpeed = backup.speechSpeed
        book.status = backup.status
        book.chapters = chapters
        book.sourceChapters = backup.sourceChapters
        book.packagedAudio = backup.packagedAudio
        book.currentStage = backup.status == .completed ? .done : book.currentStage
        book.revoiceBackup = nil
    }

    /// The new narration is in place: drop the backup and carry the
    /// listening position over (same share of the book).
    static func commit(_ book: inout BookProject, chapterAudioRoot: URL, defaults: UserDefaults = .standard) {
        guard let backup = book.revoiceBackup else { return }
        if let saved = PlaybackProgressStore.load(bookID: book.id, defaults: defaults) {
            let oldDurations = backup.chapters.sorted { $0.order < $1.order }.map { $0.audioDurationSeconds ?? 0 }
            let newDurations = book.sortedChapters.map { $0.audioDurationSeconds ?? 0 }
            if let mapped = mapPosition(saved, oldDurations: oldDurations, newDurations: newDurations, newIsPackaged: book.packagedAudio != nil) {
                PlaybackProgressStore.save(mapped, bookID: book.id, defaults: defaults)
            }
        }
        try? FileManager.default.removeItem(at: backupDirectory(bookID: book.id, root: chapterAudioRoot))
        book.revoiceBackup = nil
    }

    /// Same chapter and the same share of it when the chapter count is
    /// unchanged; otherwise the same share of the whole book.
    static func mapPosition(_ saved: PlaybackProgressStore.Saved, oldDurations: [Double], newDurations: [Double], newIsPackaged: Bool) -> PlaybackProgressStore.Saved? {
        let oldTotal = oldDurations.reduce(0, +), newTotal = newDurations.reduce(0, +)
        guard oldTotal > 0, newTotal > 0 else { return nil }
        let listened = min(oldTotal, PlaybackProgressStore.listenedSeconds(saved, chapterDurations: oldDurations))
        var chapterIndex = 0
        var withinFraction = 0.0
        if oldDurations.count == newDurations.count {
            var acc = 0.0
            for (index, duration) in oldDurations.enumerated() {
                if listened < acc + duration || index == oldDurations.count - 1 {
                    chapterIndex = index
                    withinFraction = duration > 0 ? min(1, max(0, (listened - acc) / duration)) : 0
                    break
                }
                acc += duration
            }
        } else {
            let target = listened / oldTotal * newTotal
            var acc = 0.0
            for (index, duration) in newDurations.enumerated() {
                if target < acc + duration || index == newDurations.count - 1 {
                    chapterIndex = index
                    withinFraction = duration > 0 ? min(1, max(0, (target - acc) / duration)) : 0
                    break
                }
                acc += duration
            }
        }
        let inChapter = withinFraction * newDurations[chapterIndex]
        let before = newDurations.prefix(chapterIndex).reduce(0, +)
        return PlaybackProgressStore.Saved(chapterIndex: chapterIndex,
                                           time: newIsPackaged ? before + inChapter : inChapter,
                                           isAbsolute: newIsPackaged, lastPlayedAt: saved.lastPlayedAt)
    }
}
