import Foundation

/// User-created sidebar folders (plan 9.5): simple named buckets a book can
/// be filed into manually. A folder assignment wins over the automatic
/// topic grouping. Persisted as `folders.json` in the app support
/// directory (injectable root for tests).
struct LibraryFolder: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var order: Int
}

final class FolderStore: @unchecked Sendable {
    static let shared = FolderStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [LibraryFolder]

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudiobookForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("folders.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LibraryFolder].self, from: data) {
            cache = decoded
        } else {
            cache = []
        }
    }

    func folders() -> [LibraryFolder] {
        lock.withLock { cache.sorted { $0.order < $1.order } }
    }

    func folder(id: UUID) -> LibraryFolder? {
        lock.withLock { cache.first { $0.id == id } }
    }

    @discardableResult
    func add(name: String) -> LibraryFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = LibraryFolder(
            id: UUID(),
            name: trimmed.isEmpty ? "Neuer Ordner" : trimmed,
            order: (lock.withLock { cache.map(\.order).max() } ?? 0) + 1
        )
        lock.withLock {
            cache.append(folder)
            persistLocked()
        }
        notify()
        return folder
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock {
            guard let index = cache.firstIndex(where: { $0.id == id }) else { return }
            cache[index].name = trimmed
            persistLocked()
        }
        notify()
    }

    /// Deleting a folder does NOT delete books — the caller moves them to
    /// "Sonstiges" (clears `folderID`), per plan 9.5's test.
    func delete(id: UUID) {
        lock.withLock {
            cache.removeAll { $0.id == id }
            persistLocked()
        }
        notify()
    }

    /// Posted after every add/rename/delete — sidebar and shelf both show
    /// folders and refresh on it (v3.2: a rename now updates the shelf too).
    static let didChange = Notification.Name("FolderStore.didChange")

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cache) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
