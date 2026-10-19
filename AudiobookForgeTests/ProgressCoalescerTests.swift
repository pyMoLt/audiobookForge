import XCTest
@testable import AudiobookForge

/// Phase 1 (4.1): the progress coalescer throttles UI updates to at most
/// one application per interval, applies stage changes synchronously,
/// and never drops the last queued mutation.
@MainActor
final class ProgressCoalescerTests: XCTestCase {

    private func makeCoalescer(interval: Duration = .milliseconds(250)) -> (coalescer: ProgressCoalescer, applied: LockedBox<[(UUID, Int)]>) {
        let applied = LockedBox<[(UUID, Int)]>([])
        let coalescer = ProgressCoalescer(interval: interval)
        coalescer.apply = { bookID, mutations in
            var value = RunProgress()
            value.imagesDone = 0
            for mutation in mutations { mutation(&value) }
            applied.withLock { $0.append((bookID, value.imagesDone)) }
        }
        return (coalescer, applied)
    }

    func testCoalescerEmitsAtMostFourUpdatesPerSecond() async {
        // 1000 events spread over ~1 s with the default 250 ms interval:
        // at most 5 applications (4 timed flushes + the final flush),
        // and the very last value must survive.
        let (coalescer, applied) = makeCoalescer()
        let bookID = UUID()
        let started = Date()
        for i in 1...1000 {
            coalescer.mutate(bookID: bookID) { $0.imagesDone = i }
            try? await Task.sleep(for: .milliseconds(1))
        }
        coalescer.flush()
        let elapsed = Date().timeIntervalSince(started)
        let applications = applied.withLock { $0 }
        // At most one application per interval plus the final flush —
        // i.e. ≤ 4 UI updates per second regardless of event count.
        XCTAssertLessThanOrEqual(Double(applications.count), elapsed / 0.25 + 2,
                                 "expected ≤ 4 applications/s, got \(applications.count) in \(elapsed)s")
        // Every batch carries the newest accumulated value; the final
        // applied value is the last event.
        XCTAssertEqual(applications.last?.1, 1000, "the last queued value must never be swallowed")
        // And the pending queue is empty afterwards.
        XCTAssertFalse(coalescer.hasPending)
    }

    func testBurstOfEventsResultsInSingleApplication() async {
        let (coalescer, applied) = makeCoalescer(interval: .milliseconds(200))
        let bookID = UUID()
        for i in 1...500 {
            coalescer.mutate(bookID: bookID) { $0.imagesDone = i }
            await Task.yield()
        }
        XCTAssertEqual(applied.withLock { $0 }.count, 0, "burst inside one interval must not apply yet")
        try? await Task.sleep(for: .milliseconds(300))
        let applications = applied.withLock { $0 }
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications.first?.1, 500, "all queued mutations fold into one application with the newest value")
    }

    func testStageChangeBypassesCoalescer() {
        let (coalescer, applied) = makeCoalescer()
        let bookID = UUID()
        coalescer.mutate(bookID: bookID, immediate: true) { $0.imagesDone = 7 }
        // Immediate application happened synchronously — no sleep.
        XCTAssertEqual(applied.withLock { $0 }.count, 1)
        XCTAssertEqual(applied.withLock { $0 }.first?.1, 7)
        XCTAssertEqual(coalescer.applicationCount, 1)
        XCTAssertFalse(coalescer.hasPending)
    }

    func testDropDiscardsPendingMutations() async {
        let (coalescer, applied) = makeCoalescer(interval: .milliseconds(500))
        let bookID = UUID()
        coalescer.mutate(bookID: bookID) { $0.imagesDone = 3 }
        coalescer.drop(bookID: bookID)
        XCTAssertTrue(coalescer.hasPending == false)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(applied.withLock { $0 }.count, 0, "dropped book must not be applied")
    }

    func testDifferentBooksAreFlushedIndependently() async {
        let (coalescer, applied) = makeCoalescer()
        let a = UUID(), b = UUID()
        coalescer.mutate(bookID: a) { $0.imagesDone = 1 }
        coalescer.mutate(bookID: b) { $0.imagesDone = 2 }
        coalescer.flush(bookID: a)
        let applications = applied.withLock { $0 }
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications.first?.0, a)
        XCTAssertTrue(coalescer.hasPending, "book b must still be pending")
    }
}
