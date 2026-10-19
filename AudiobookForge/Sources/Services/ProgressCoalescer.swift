import Foundation

/// Throttles `RunProgress` mutations: pipeline workers fire segment
/// events several times per second, and every one of them used to make
/// SwiftUI re-evaluate the whole progress panel. The coalescer collects
/// mutations and applies them at most once per interval (default 250 ms
/// → ≤ 4 UI updates/s regardless of worker count).
///
/// Stage switches and completions pass `immediate: true` (or call
/// `flush`) and are applied synchronously, so a reset never waits for a
/// timer. The last collected mutation is never dropped: `flush` applies
/// everything still pending.
@MainActor
final class ProgressCoalescer {
    private let interval: Duration
    /// Set by the owner right after init (avoids capturing `self` of an
    /// `@Observable` class during initialization). Applies a batch of
    /// queued mutations to the live progress entry of a book.
    var apply: (@MainActor (_ bookID: UUID, _ mutations: [(inout RunProgress) -> Void]) -> Void)?
    private var pending: [UUID: [(inout RunProgress) -> Void]] = [:]
    private var flushTask: Task<Void, Never>?
    /// Test hook: how often mutations were actually applied.
    private(set) var applicationCount = 0

    init(interval: Duration = .milliseconds(250)) {
        self.interval = interval
    }

    var hasPending: Bool { !pending.isEmpty }

    /// Queues a mutation; `immediate` applies it (plus everything already
    /// queued for this book) right away instead of waiting for the timer.
    func mutate(bookID: UUID, immediate: Bool = false, _ mutation: @escaping (inout RunProgress) -> Void) {
        pending[bookID, default: []].append(mutation)
        if immediate {
            flush(bookID: bookID)
        } else {
            scheduleFlush()
        }
    }

    /// Applies everything pending (`bookID` limits the flush to one book).
    func flush(bookID: UUID? = nil) {
        flushTask?.cancel()
        flushTask = nil
        guard let apply else {
            pending = [:]
            return
        }
        if let bookID {
            guard let mutations = pending.removeValue(forKey: bookID), !mutations.isEmpty else { return }
            applicationCount += 1
            apply(bookID, mutations)
        } else {
            let all = pending
            pending = [:]
            for (id, mutations) in all where !mutations.isEmpty {
                applicationCount += 1
                apply(id, mutations)
            }
        }
    }

    /// Discards pending mutations (book finished/failed — the progress
    /// entry is about to disappear anyway).
    func drop(bookID: UUID) {
        pending[bookID] = nil
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: self?.interval ?? .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }
}
