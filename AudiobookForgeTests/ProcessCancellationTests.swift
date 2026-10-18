import Foundation
import XCTest
@testable import AudiobookForge

final class ProcessCancellationTests: XCTestCase {
    func testCancellingRunnerTerminatesChildProcess() async throws {
        let started = Date()
        let task = Task {
            try await FFmpegRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
    }
}
