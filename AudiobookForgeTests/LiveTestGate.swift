import XCTest

/// Tests that talk to a real LLM endpoint or touch the user's real
/// library run only on request (v4.1): `TEST_RUNNER_ABF_LIVE_TESTS=1
/// xcodebuild test …`. They load models into oMLX and take minutes, and
/// they must never write into the app's library or settings unasked.
enum LiveTestGate {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["ABF_LIVE_TESTS"] == "1" }

    static func require(_ what: String = "Live-Test") throws {
        guard isEnabled else {
            throw XCTSkip("\(what) läuft nur mit ABF_LIVE_TESTS=1 (TEST_RUNNER_ABF_LIVE_TESTS=1).")
        }
    }

    /// A fresh directory for a live test's library, settings and output.
    static func scratchDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abf-live-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
