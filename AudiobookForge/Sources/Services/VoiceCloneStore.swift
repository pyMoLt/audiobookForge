import Foundation

/// One user-recorded or imported reference voice for voice cloning
/// (user request 2026-10-18): engines that support cloning (currently
/// OmniVoice) render chapters with this voice instead of a preset.
///
/// A clone is engine-NEUTRAL data (audio + transcript): the gallery picks
/// the best cloning-capable engine available when rendering. The voice
/// string convention on `VoiceID` is `"clone:<uuid>"` — engines resolve it
/// back to the store.
struct VoiceClone: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// BCP-47-ish language of the recording ("de").
    var languageCode: String
    /// What is said in the reference audio — required by OmniVoice for a
    /// good speaker embedding. Empty = the model trims at a silence gap.
    var refText: String
    /// File name inside the clones directory.
    var audioFileName: String
    var createdAt: Date = Date()
}

/// Owns the user's cloned voices: one audio file + one metadata record
/// each, persisted in `Application Support/AudiobookForge/voice_clones/`
/// (`clones.json` + `<uuid>.<ext>`). Never touches anything else — real
/// library data stays untouched.
final class VoiceCloneStore: @unchecked Sendable {
    /// Voice id for a clone under the given (cloning-capable) engine —
    /// the gallery decides via `AppSettings.preferredCloneEngine`.
    static func voiceID(for clone: VoiceClone, engine: TTSEngineID) -> VoiceID {
        VoiceID(engine: engine, voice: "clone:\(clone.id.uuidString)")
    }

    static let shared = VoiceCloneStore()

    private let root: URL
    private let lock = NSLock()
    private var cache: [VoiceClone]

    /// `root` is injectable so tests run against a temp directory.
    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudiobookForge/voice_clones", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.cache = Self.load(from: base)
    }

    // MARK: - API

    func clones() -> [VoiceClone] {
        lock.withLock { cache.sorted { $0.createdAt > $1.createdAt } }
    }

    func clone(id: UUID) -> VoiceClone? {
        lock.withLock { cache.first { $0.id == id } }
    }

    func clone(forVoice voice: String) -> VoiceClone? {
        guard voice.hasPrefix("clone:") else { return nil }
        guard let id = UUID(uuidString: String(voice.dropFirst("clone:".count))) else { return nil }
        return clone(id: id)
    }

    /// Absolute audio URL of a clone (nil if the file vanished).
    func audioURL(for clone: VoiceClone) -> URL? {
        let url = root.appendingPathComponent(clone.audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Registers a reference voice. `audioURL` points at a recording or an
    /// imported file — it is COPIED into the store so deleting the source
    /// (e.g. a temp recording) doesn't break the clone.
    @discardableResult
    func add(name: String, refText: String, languageCode: String, audioURL: URL) throws -> VoiceClone {
        let cloneID = UUID()
        let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
        let fileName = "\(cloneID.uuidString).\(ext)"
        let destination = root.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.copyItem(at: audioURL, to: destination)

        let clone = VoiceClone(
            id: cloneID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Eigene Stimme" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            languageCode: languageCode,
            refText: refText.trimmingCharacters(in: .whitespacesAndNewlines),
            audioFileName: fileName
        )
        try lock.withLock {
            cache.append(clone)
            try Self.persist(cache, to: root)
        }
        return clone
    }

    func delete(id: UUID) {
        lock.withLock {
            guard let index = cache.firstIndex(where: { $0.id == id }) else { return }
            let clone = cache.remove(at: index)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(clone.audioFileName))
            try? Self.persist(cache, to: root)
        }
    }

    // MARK: - Persistence

    private static func load(from directory: URL) -> [VoiceClone] {
        let index = directory.appendingPathComponent("clones.json")
        guard let data = try? Data(contentsOf: index),
              let decoded = try? JSONDecoder().decode([VoiceClone].self, from: data) else { return [] }
        return decoded
    }

    private static func persist(_ clones: [VoiceClone], to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clones)
        try data.write(to: directory.appendingPathComponent("clones.json"), options: .atomic)
    }
}
