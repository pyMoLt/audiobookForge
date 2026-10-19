import Foundation

/// App language (v3.1): System follows macOS, or force German / English.
/// Applied through the app's `AppleLanguages` override on the next launch
/// (the settings page offers an immediate restart).
enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case de
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("System")
        case .de: return "Deutsch"
        case .en: return "English"
        }
    }

    /// Writes (or clears) the per-app language override.
    func apply(defaults: UserDefaults = .standard) {
        switch self {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .de: defaults.set(["de"], forKey: "AppleLanguages")
        case .en: defaults.set(["en"], forKey: "AppleLanguages")
        }
    }

    /// Language the UI is currently shown in ("de" / "en").
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "de"
    }
}

/// Looks up a UI string (German source text) in the String Catalog.
/// Used for display names that are stored or passed around as `String`;
/// SwiftUI literals (`Text("…")`) are looked up automatically.
@inline(__always)
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}
