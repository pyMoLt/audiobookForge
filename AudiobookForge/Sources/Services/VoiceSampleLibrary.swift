import Foundation

/// Bundled voice samples (v4): a few seconds per voice of every engine,
/// rendered once with the real engines (`scripts/build_voice_samples.sh`)
/// and shipped as small AAC files, so every voice can be heard before its
/// engine or model is installed. Live previews (book text, own voices,
/// macOS voices) still synthesize on demand.
enum VoiceSampleLibrary {
    struct Entry: Codable, Sendable {
        let file: String
        let text: String
    }

    static func key(_ id: VoiceID) -> String { "\(id.engine.rawValue):\(id.voice)" }

    /// File name for a voice — unique and flat (resources may be flattened).
    static func fileName(_ id: VoiceID) -> String {
        // ASCII only: accented names ("Noémie") would depend on the Unicode
        // form the file system stores.
        let folded = id.voice.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let voice = folded.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return "sample_\(id.engine.rawValue)_\(voice).m4a"
    }

    static let index: [String: Entry] = {
        guard let url = Bundle.main.url(forResource: "voice_samples", withExtension: "json", subdirectory: "VoiceSamples")
            ?? Bundle.main.url(forResource: "voice_samples", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return decoded
    }()

    static func has(_ id: VoiceID) -> Bool { index[key(id)] != nil }

    /// The bundled sample when `text` is the one it was rendered with (or
    /// nil text = "any sample").
    static func url(for id: VoiceID, text: String? = nil) -> URL? {
        guard let entry = index[key(id)] else { return nil }
        if let text, entry.text != text { return nil }
        let name = (entry.file as NSString).deletingPathExtension
        return Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "VoiceSamples")
            ?? Bundle.main.url(forResource: name, withExtension: "m4a")
    }
}
