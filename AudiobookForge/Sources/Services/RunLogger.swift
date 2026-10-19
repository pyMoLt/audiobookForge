import Foundation

/// One append-only log file per processing run, so a failed conversion can be
/// diagnosed after the fact without re-running anything.
final class RunLogger: @unchecked Sendable {
    let fileURL: URL
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "AudiobookForge.RunLogger")
    /// Mirrors every line to the live progress view (set by the pipeline).
    var onLine: (@Sendable (String) -> Void)?

    /// `directory` lets tests run against an isolated folder instead of
    /// the user's real logs directory.
    init(bookID: UUID, bookTitle: String, directory customDirectory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = customDirectory ?? appSupport.appendingPathComponent("AudiobookForge/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.rotate(directory: directory, maxFiles: Self.maxLogFiles - 1, maxBytes: Self.maxLogBytes)

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

    static let maxLogFiles = 20
    static let maxLogBytes = 50 * 1_024 * 1_024

    /// Deletes the oldest `.log` files until at most `maxFiles` remain and
    /// their total size is within `maxBytes`.
    static func rotate(directory: URL, maxFiles: Int, maxBytes: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = urls.filter { $0.pathExtension == "log" }.map { url -> (url: URL, date: Date, size: Int) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }
        entries.sort { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        while let oldest = entries.first, entries.count > maxFiles || total > maxBytes {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            entries.removeFirst()
        }
    }
}

