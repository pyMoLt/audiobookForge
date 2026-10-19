import XCTest
@testable import AudiobookForge

/// Phase 1 (4.2): ProcessRunner must not park cooperative-pool threads,
/// must support cancellation within 3 s, and must stream large outputs
/// (5 MB) without deadlocking.
final class ProcessRunnerTests: XCTestCase {

    /// 16 parallel `sleep 0.3` processes must not starve the
    /// cooperative pool: a concurrently running counting task keeps
    /// making progress while all 16 are in flight.
    func testParallelProcessesDoNotBlockCooperativePool() async throws {
        let counter = LockedBox<Int>(0)
        let countingTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                counter.withLock { $0 += 1 }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { countingTask.cancel() }

        try await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    _ = try? await ProcessRunner.run(
                        executable: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["0.3"]
                    )
                }
            }
            while await group.next() != nil {}
        }

        let ticks = counter.withLock { $0 }
        XCTAssertGreaterThan(ticks, 10, "counting task starved — pool was blocked by waitUntilExit-style waiting")
    }

    /// Cancelling the awaiting task terminates the child within 3 s.
    func testCancellationTerminatesChildQuickly() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0)
    }

    /// 5 MB of output stream through the readability handlers without a
    /// deadlock (a fixed pipe buffer would fill at 64 KB).
    func testLargeOutputIsStreamedWithoutDeadlock() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1000", "count=5000"]
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.count, 5_000_000)
        XCTAssertFalse(result.standardError.isEmpty, "dd writes its summary to stderr")
    }

    func testExitStatusAndStderrAreReported() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        )
        XCTAssertEqual(result.terminationStatus, 1)
    }
}
