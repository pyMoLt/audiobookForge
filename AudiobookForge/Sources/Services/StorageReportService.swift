import Foundation

public struct StorageItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let directory: URL
    public let byteCount: Int64
    public let isEssential: Bool

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter.string(fromByteCount: byteCount)
    }
}

public final class StorageReportService: Sendable {
    public static let shared = StorageReportService()

    public init() {}

    public static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public func fetchReport(baseDirectory: URL? = nil) async -> [StorageItem] {
        let base = baseDirectory ?? AppPaths.applicationSupportDirectory
        let itemsConfig: [(id: String, name: String, subpath: String, essential: Bool)] = [
            ("bridge", "Kokoro-Laufzeitumgebung (MLX/Python)", "bridge", true),
            ("bridge_piper", "Piper-Laufzeitumgebung (Python)", "bridge_piper", true),
            ("models", "Modelle & Stimmen", "models", false),
            ("chapter_audio", "Zwischengespeichertes Kapitel-Audio", "chapter_audio", false),
            ("logs", "Verarbeitungsprotokolle", "logs", false),
            ("backups", "Sicherungsdateien (Backups)", "backups", false),
        ]

        var results: [StorageItem] = []
        for config in itemsConfig {
            let dir = base.appendingPathComponent(config.subpath, isDirectory: true)
            let bytes = Self.directorySize(at: dir)
            results.append(StorageItem(
                id: config.id,
                name: config.name,
                directory: dir,
                byteCount: bytes,
                isEssential: config.essential
            ))
        }
        return results
    }

    public func clean(item: StorageItem) throws {
        guard !item.isEssential else {
            // For bridge / environments, we remove the venv contents but preserve the directory
            if FileManager.default.fileExists(atPath: item.directory.path) {
                try FileManager.default.removeItem(at: item.directory)
            }
            return
        }
        if FileManager.default.fileExists(atPath: item.directory.path) {
            let contents = try FileManager.default.contentsOfDirectory(at: item.directory, includingPropertiesForKeys: nil)
            for file in contents {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    public func cleanAllNonEssential(baseDirectory: URL? = nil) throws {
        let base = baseDirectory ?? AppPaths.applicationSupportDirectory
        let targets = ["chapter_audio", "logs", "backups"]
        for target in targets {
            let dir = base.appendingPathComponent(target, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.path) {
                let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for file in contents {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
