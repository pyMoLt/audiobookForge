import Foundation
import AppKit
import Observation

/// The app's library. Public API is unchanged from v2 (`books`, `upsert`,
/// `remove`, `book(id:)`) — internally it supports two on-disk layouts:
///
/// - **v2** (pre-migration, and the layout every test fixture uses): one
///   `library.json` holding the full `[BookProject]` array. Behavior is
///   byte-for-byte the Phase 1 implementation (debounced writes, ≤ 1
///   write / 2 s under sustained updates, flush on quit).
/// - **v3** (plan 5.1): a small `library/index.json` plus per-book
///   directories (`book.json` metadata, `text/*.json`, cover files).
///   Startup reads only the index and metadata; chapter texts are
///   hydrated lazily on the first `book(id:)` access. Writes touch only
///   the book that changed (`dirtyBookIDs`), and the (large) text files
///   are only re-encoded when the texts actually changed.
@Observable
final class LibraryStore: @unchecked Sendable {
    var books: [BookProject] = []

    /// Root directory of the library — for pure, off-main reads via
    /// `LibraryLayout` (e.g. the background topic classification).
    var rootURL: URL { root }

    /// Deutschsprachiger Hinweis- oder Fehlerbanner (z. B. wenn die
    /// v2→v3-Migration fehlgeschlagen ist und die App mit den v2-Daten
    /// weiterläuft). Shown by `ContentView`.
    var migrationNotice: String?

    private let root: URL
    private let legacyFileURL: URL
    private var usesV3Layout = false
    private var isLoading = false

    /// Guards `books`, hydration state and the persisted baselines
    /// (all callers are effectively main-actor, but the persistence
    /// queue snapshots state concurrently).
    private let stateLock = NSRecursiveLock()
    private var hydratedBookIDs: Set<UUID> = []
    /// Last state actually written to disk per book (v3) — baseline for
    /// the "texts changed?" diff that keeps big text files from being
    /// re-encoded on every chapter status update.
    private var persistedSnapshots: [UUID: BookProject] = [:]
    private var persistedCoverData: [UUID: Data] = [:]
    private let dirtyBookIDs = LockedBox<Set<UUID>>([])
    private var indexDirty = false

    /// `fileURL` lets tests run against an isolated file instead of the
    /// user's real one in Application Support. `root` pins the whole
    /// library directory (v3 layout); when omitted it is derived from
    /// the file URL's parent directory.
    init(fileURL customFileURL: URL? = nil, root customRoot: URL? = nil, debounceInterval: TimeInterval = 0.4, maxDirtyAge: TimeInterval = 2.0) {
        let defaultRoot = AppPaths.applicationSupportDirectory
        let resolvedRoot = customRoot ?? customFileURL?.deletingLastPathComponent() ?? defaultRoot
        root = resolvedRoot
        legacyFileURL = customFileURL ?? resolvedRoot.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.debounceInterval = debounceInterval
        self.maxDirtyAge = maxDirtyAge

        isLoading = true
        if LibraryLayout.hasV3Index(root) {
            usesV3Layout = true
            loadIndexAndMetadata()
            prefetchHydration()
        } else if let data = try? Data(contentsOf: legacyFileURL),
                  let decoded = try? JSONDecoder().decode([BookProject].self, from: data) {
            books = decoded
            // v2 payloads always contain the texts — everything is loaded.
            hydratedBookIDs = Set(decoded.map(\.id))
        }
        isLoading = false
    }

    // MARK: - Public API (unchanged)

    func upsert(_ book: BookProject) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
        } else {
            books.append(book)
        }
        if usesV3Layout {
            dirtyBookIDs.withLock { $0.insert(book.id) }
            indexDirty = true
        }
        schedulePersist()
    }

    func remove(_ book: BookProject) {
        stateLock.lock(); defer { stateLock.unlock() }
        books.removeAll { $0.id == book.id }
        LibraryLayout.removeBookDirectory(bookID: book.id, root: root)
        persistedSnapshots[book.id] = nil
        persistedCoverData[book.id] = nil
        hydratedBookIDs.remove(book.id)
        if usesV3Layout {
            indexDirty = true
        }
        ChapterAudioStore.removeChapterAudio(bookID: book.id)
        let logsDir = AppPaths.applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        if let logFiles = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
            for file in logFiles where file.lastPathComponent.contains(book.id.uuidString) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        schedulePersist()
    }

    func book(id: UUID) -> BookProject? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let index = books.firstIndex(where: { $0.id == id }) else { return nil }
        if usesV3Layout, !hydratedBookIDs.contains(id) {
            var book = books[index]
            let stored = LibraryLayout.readStoredBook(bookID: id, root: root)
            LibraryLayout.hydrate(&book, root: root, sourceChaptersSameAsRaw: stored?.sourceChaptersSameAsRaw ?? false)
            books[index] = book
            hydratedBookIDs.insert(id)
            if persistedSnapshots[id] == nil { persistedSnapshots[id] = book }
            if persistedCoverData[id] == nil { persistedCoverData[id] = book.coverImageData }
        }
        return books[index]
    }

    /// Background pre-hydration (v3): hydrates unhydrated books off the main
    /// actor so clicking any book opens instantly without I/O stalls.
    func prefetchHydration() {
        guard usesV3Layout else { return }
        let root = self.root
        let unhydrated = getUnhydratedBookIDs()
        guard !unhydrated.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            for bookID in unhydrated {
                guard let self else { return }
                if self.isBookHydrated(id: bookID) { continue }

                let stored = LibraryLayout.readStoredBook(bookID: bookID, root: root)
                if var book = stored?.book {
                    LibraryLayout.hydrate(&book, root: root, sourceChaptersSameAsRaw: stored?.sourceChaptersSameAsRaw ?? false)
                    await MainActor.run {
                        self.applyHydratedBook(book, id: bookID)
                    }
                }
            }
        }
    }

    private func getUnhydratedBookIDs() -> [UUID] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return books.map(\.id).filter { !hydratedBookIDs.contains($0) }
    }

    private func isBookHydrated(id: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return hydratedBookIDs.contains(id)
    }

    private func applyHydratedBook(_ book: BookProject, id: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let index = books.firstIndex(where: { $0.id == id }), !hydratedBookIDs.contains(id) {
            books[index] = book
            hydratedBookIDs.insert(id)
            if persistedSnapshots[id] == nil { persistedSnapshots[id] = book }
            if persistedCoverData[id] == nil { persistedCoverData[id] = book.coverImageData }
        }
    }

    // MARK: - Loading (v3)

    /// Startup only reads the index and the per-book metadata files —
    /// texts and covers load lazily via `book(id:)`.
    private func loadIndexAndMetadata() {
        guard let data = try? Data(contentsOf: LibraryLayout.indexURL(root)),
              let index = try? LibraryLayout.decodeIndex(data) else { return }
        var loaded: [BookProject] = []
        for entry in index.books {
            if let stored = LibraryLayout.readStoredBook(bookID: entry.id, root: root) {
                loaded.append(stored.book)
            }
        }
        books = loaded
    }

    // MARK: - Persistence
    //
    // Writes are coalesced and done off the main thread (Phase 1, 4.4):
    // a pure trailing debounce starved under sustained updates, so a dirty
    // state is force-flushed once it is older than `maxDirtyAge` (2 s).
    // In v3 mode only the dirty books (and the small index) are written.

    private let persistQueue = DispatchQueue(label: "AudiobookForge.LibraryStore.persist", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private let firstDirtyAt = LockedBox<Date?>(nil)
    private let debounceInterval: TimeInterval
    private let maxDirtyAge: TimeInterval
    private var terminationObserver: NSObjectProtocol?

    /// Test hook: number of completed disk writes (see
    /// `PersistenceDebounceTests`).
    static let writeCount = LockedBox<Int>(0)

    private struct PersistSnapshot {
        var v2Books: [BookProject]?
        var dirtyBooks: [BookProject] = []
        var allBooks: [BookProject] = []
        var index: LibraryLayout.LibraryIndex?
        /// Book IDs whose narration texts changed (v3) — only those get
        /// their (large) text files re-encoded.
        var bookIDsNeedingTextWrite: Set<UUID> = []
        var bookIDsNeedingCoverWrite: Set<UUID> = []
    }

    private func schedulePersist() {
        guard !isLoading else { return }
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.flush()
            }
        }
        pendingWrite?.cancel()
        if firstDirtyAt.withLock({ $0 }) == nil { firstDirtyAt.withLock { $0 = Date() } }
        let dirtyAge = firstDirtyAt.withLock { $0.map { Date().timeIntervalSince($0) } } ?? 0
        if dirtyAge >= maxDirtyAge {
            // Dirty for ≥ maxDirtyAge without a quiet moment: write now
            // instead of starving forever.
            firstDirtyAt.withLock { $0 = nil }
            pendingWrite = nil
            persistQueue.async { self.writeNow(self.makePersistSnapshot()) }
            return
        }
        // The snapshot is built when the write actually happens (not here):
        // building it early consumed the dirty set, and a later flush()
        // cancelled the pending job — silently dropping that write.
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firstDirtyAt.withLock { $0 = nil }
            self.writeNow(self.makePersistSnapshot())
        }
        pendingWrite = item
        persistQueue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Builds the immutable snapshot to write. Runs under `stateLock` so
    /// the persistence queue never observes a half-mutated library.
    private func makePersistSnapshot() -> PersistSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        var snapshot = PersistSnapshot()
        if usesV3Layout {
            let dirty = dirtyBookIDs.withLock { $0 }
            dirtyBookIDs.withLock { $0 = [] }
            snapshot.dirtyBooks = books.filter { dirty.contains($0.id) }
            snapshot.allBooks = books
            if indexDirty {
                snapshot.index = LibraryLayout.LibraryIndex(
                    schemaVersion: LibraryLayout.schemaVersion,
                    books: books.map { LibraryLayout.indexEntry(for: $0, root: root) }
                )
                indexDirty = false
            }
            for book in snapshot.dirtyBooks {
                let persisted = persistedSnapshots[book.id]
                let hasBaseline = persisted != nil
                // Books that were never hydrated (metadata-only, e.g. a
                // status tweak taken straight from `books`) must not
                // overwrite the texts on disk with empty strings.
                let textsChanged = hasBaseline
                    ? hydratedBookIDs.contains(book.id) && LibraryLayout.textsDiffer(book, persisted: persisted)
                    : true
                if textsChanged { snapshot.bookIDsNeedingTextWrite.insert(book.id) }
                if book.coverImageData != persistedCoverData[book.id] {
                    snapshot.bookIDsNeedingCoverWrite.insert(book.id)
                }
            }
        } else {
            snapshot.v2Books = books
        }
        return snapshot
    }

    private func writeNow(_ snapshot: PersistSnapshot) {
        if let v2Books = snapshot.v2Books {
            Self.write(v2Books, to: legacyFileURL)
            return
        }
        var written: [UUID: BookProject] = [:]
        for book in snapshot.dirtyBooks {
            do {
                try LibraryLayout.writeBook(
                    book,
                    root: root,
                    writeTexts: snapshot.bookIDsNeedingTextWrite.contains(book.id)
                )
                if snapshot.bookIDsNeedingCoverWrite.contains(book.id), book.coverImageData != nil {
                    try LibraryLayout.writeCoverFiles(book, root: root)
                }
                written[book.id] = book
            } catch {
                // Keep the book dirty so the next flush retries the write.
                dirtyBookIDs.withLock { $0.insert(book.id) }
            }
        }
        if let index = snapshot.index {
            if let data = try? LibraryLayout.encodeIndex(index) {
                try? data.write(to: LibraryLayout.indexURL(root), options: .atomic)
            }
        }
        // Update the diff baselines after a successful write.
        stateLock.lock(); defer { stateLock.unlock() }
        for (id, book) in written {
            // A metadata-only book carries no texts — the previous
            // baseline's texts are still what is on disk.
            if hydratedBookIDs.contains(id) || persistedSnapshots[id] == nil {
                persistedSnapshots[id] = book
            }
            persistedCoverData[id] = book.coverImageData
        }
        if !written.isEmpty || snapshot.index != nil {
            Self.writeCount.withLock { $0 += 1 }
        }
    }

    /// Writes the current state synchronously (used on quit and in tests).
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        firstDirtyAt.withLock { $0 = nil }
        persistQueue.sync { self.writeNow(self.makePersistSnapshot()) }
    }

    private static func write(_ books: [BookProject], to url: URL) {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: url, options: .atomic)
        writeCount.withLock { $0 += 1 }
    }
}
