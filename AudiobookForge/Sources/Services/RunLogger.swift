import Foundation

/// One append-only log file per processing run, so a failed conversion can be
/// diagnosed after the fact without re-running anything.
final class RunLogger: @unchecked Sendable {
    let fileURL: URL
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "AudiobookForge.RunLogger")
    /// Mirrors every line to the live progress view (set by the pipeline).
    var onLine: (@Sendable (String) -> Void)?

    init(bookID: UUID, bookTitle: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("AudiobookForge/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        fileURL = directory.appendingPathComponent("\(timestamp)-\(bookID.uuidString).log")

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = FileHandle(forWritingAtPath: fileURL.path)
        log("=== Verarbeitungslauf für \"\(bookTitle)\" gestartet ===")
    }

    func log(_ message: String) {
        queue.sync {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            handle?.seekToEndOfFile()
            handle?.write(Data(line.utf8))
        }
        onLine?(message)
    }

    func close() {
        queue.sync {
            handle?.closeFile()
        }
    }
}
