import Foundation
import Observation

@Observable
final class SettingsStore: @unchecked Sendable {
    var settings: AppSettings {
        didSet { persist() }
    }

    private let fileURL: URL

    /// `fileURL` lets tests run against an isolated file instead of the
    /// user's real one in Application Support.
    init(fileURL customFileURL: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("AudiobookForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = customFileURL ?? directory.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
