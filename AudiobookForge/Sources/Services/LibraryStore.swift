import Foundation
import AppKit
import Observation

@Observable
final class LibraryStore: @unchecked Sendable {
    var books: [BookProject] = [] {
        didSet { persist() }
    }

    private let fileURL: URL
    private var isLoading = false

    /// `fileURL` lets tests run against an isolated file instead of the
    /// user's real one in Application Support.
    init(fileURL customFileURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("AudiobookForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = customFileURL ?? directory.appendingPathComponent("library.json")

        isLoading = true
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([BookProject].self, from: data) {
            books = decoded
        }
        isLoading = false
    }

    func upsert(_ book: BookProject) {
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
        } else {
            books.append(book)
        }
    }

    func remove(_ book: BookProject) {
        books.removeAll { $0.id == book.id }
    }

    func book(id: UUID) -> BookProject? {
        books.first { $0.id == id }
    }

    /// Writes are coalesced and done off the main thread: the library
    /// holds whole books (a 700-page textbook alone is several MB of
    /// JSON), and encoding it synchronously on every chapter status change
    /// froze the UI (beach ball) at the start of a run. The latest snapshot
    /// wins; on quit it is written immediately.
    private let persistQueue = DispatchQueue(label: "AudiobookForge.LibraryStore.persist", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    private func persist() {
        guard !isLoading else { return }
        let snapshot = books
        let url = fileURL
        pendingWrite?.cancel()
        let item = DispatchWorkItem { Self.write(snapshot, to: url) }
        pendingWrite = item
        persistQueue.asyncAfter(deadline: .now() + 0.4, execute: item)
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.flush()
            }
        }
    }

    /// Writes the current state synchronously (used on quit and in tests).
    func flush() {
        pendingWrite?.cancel()
        let snapshot = books
        let url = fileURL
        persistQueue.sync { Self.write(snapshot, to: url) }
    }

    private static func write(_ books: [BookProject], to url: URL) {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
