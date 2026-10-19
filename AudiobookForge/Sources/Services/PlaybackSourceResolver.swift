import Foundation

/// Resolves where the in-app player should stream a book from (plan 5.2),
/// in this order:
/// (a) the verified packaged single-file output (`packagedAudio`, bookmark
///     resolved — the M4B may live on an external volume),
/// (b) the per-chapter audio files,
/// (c) neither → a `missing` state with a clear German message. The app
///     must not crash or block when the volume is offline, so all file
///     access happens off the caller's actor with a 2 s timeout.
enum PlaybackSourceResolver {
    enum Source {
        /// Packaged single-file output (M4B/M4A) plus the sorted chapters
        /// (for `audioStartSeconds` chapter jumps).
        case packaged(URL, [Chapter])
        /// Per-chapter audio files plus each chapter's segment timings.
        case chapterFiles([URL], [[TTSSegment]])
        /// Nothing playable found. `volumeName` names the offline volume
        /// when it is known.
        case missing(volumeName: String?)
    }

    static let missingVolumeMessage = "Ausgabe nicht gefunden — Volume verbunden?"

    /// Resolves the bookmark of a packaged output. Returns nil when the
    /// file is not accessible (offline volume, moved/deleted output).
    static func resolvePackagedURL(_ info: PackagedAudioInfo) -> URL? {
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: info.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale),
            FileManager.default.isReadableFile(atPath: url.path) {
            return url
        }
        // Fall back to the stored plain path (non-sandboxed app).
        if FileManager.default.isReadableFile(atPath: info.url.path) {
            return info.url
        }
        return nil
    }

    static func resolve(book: BookProject, timeoutSeconds: TimeInterval = 2) async -> Source {
        if let packaged = book.packagedAudio {
            let boxed: TimedBox<URL?>? = await withTimeout(seconds: timeoutSeconds) {
                TimedBox(value: resolvePackagedURL(packaged))
            }
            if let boxed, let url = boxed.value {
                return .packaged(url, book.sortedChapters)
            }
        }

        let sorted = book.sortedChapters
        let readyURLs = sorted.filter {
            $0.audioStatus == .ready && $0.audioFileURL != nil && FileManager.default.isReadableFile(atPath: $0.audioFileURL!.path)
        }
        if !readyURLs.isEmpty {
            let byChapterID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let urls = readyURLs.compactMap(\.audioFileURL)
            let segments = readyURLs.map { byChapterID[$0.id]?.audioSegments ?? [] }
            return .chapterFiles(urls, segments)
        }

        return .missing(volumeName: volumeName(of: book))
    }

    /// Best-effort volume name for the error message (e.g. the external
    /// disk holding the user's output folder).
    static func volumeName(of book: BookProject) -> String? {
        let candidates = [book.packagedAudio?.url, book.outputDirectoryURL].compactMap { $0 }
        for url in candidates {
            if let values = try? url.resourceValues(forKeys: [.volumeNameKey]), let name = values.volumeName {
                return name
            }
        }
        return nil
    }

    /// Boxes an operation result so optionals survive the timeout race
    /// (`withTimeout` adds its own `?` for the timeout case).
    struct TimedBox<Value: Sendable>: Sendable {
        let value: Value
    }

    /// Races `operation` against a timeout — an offline network volume can
    /// hang a plain `isReadableFile` check, and the player must never
    /// block (let alone the main thread) on that.
    static func withTimeout<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            return await group.next() ?? nil
        }
    }
}
