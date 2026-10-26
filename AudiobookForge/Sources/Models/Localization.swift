import Foundation

/// App language (v3.1): System follows macOS, or force German / English.
/// Applied through the app's `AppleLanguages` override on the next launch
/// (the settings page offers an immediate restart).
enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case de
    case en
    // v4: further main languages.
    case fr
    case es
    case it

    var id: String { rawValue }

    /// The concrete languages (without "system").
    static let concrete: [AppLanguage] = [.de, .en, .fr, .es, .it]

    /// The UI language "system" resolves to: the Mac's first preferred
    /// language if the app has it, else English.
    static func resolvedSystemLanguage(_ preferred: [String] = Locale.preferredLanguages) -> String {
        for code in preferred.map({ String($0.prefix(2)) }) where concrete.map(\.rawValue).contains(code) {
            return code
        }
        return "en"
    }

    var displayName: String {
        switch self {
        case .system: return L("System")
        case .de: return "Deutsch"
        case .en: return "English"
        case .fr: return "Français"
        case .es: return "Español"
        case .it: return "Italiano"
        }
    }

    /// Writes (or clears) the per-app language override.
    func apply(defaults: UserDefaults = .standard) {
        switch self {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        default: defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Language the UI is currently shown in ("de", "en", "fr", "es", "it").
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
