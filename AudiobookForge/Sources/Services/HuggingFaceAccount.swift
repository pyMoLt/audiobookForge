import Foundation
import Security

/// The user's Hugging Face sign-in (v4): one read token for every gated
/// model (Phonon 40m, Pocket TTS). Stored in the login keychain, never in
/// settings.json or logs. A token saved by `hf auth login` is picked up as a
/// fallback, so a Mac that already signed in on the command line works
/// without entering it again.
enum HuggingFaceAccount {
    private static let service = "AudiobookForge.HuggingFace"
    private static let account = "token"

    /// Test hook: replaces keychain + CLI-token lookup.
    nonisolated(unsafe) static var tokenOverride: String??

    static var token: String? {
        if let tokenOverride { return tokenOverride }
        return keychainToken ?? cliToken
    }

    static var hasToken: Bool { token?.isEmpty == false }

    /// Where the token comes from, for the settings row.
    static var tokenSource: String? {
        if keychainToken != nil { return L("Schlüsselbund") }
        if cliToken != nil { return L("Hugging-Face-Kommandozeile") }
        return nil
    }

    static func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static var keychainToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private static var cliToken: String? {
        let env = ProcessInfo.processInfo.environment
        if let fromEnv = env["HF_TOKEN"], !fromEnv.isEmpty { return fromEnv }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home.appendingPathComponent(".cache/huggingface/token")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Environment for download processes: the token as HF_TOKEN (the only
    /// place it leaves the keychain).
    static func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        if let token { env["HF_TOKEN"] = token }
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        return env
    }

    // MARK: - Remote checks

    enum AccessState: Equatable, Sendable {
        case granted
        /// Signed in, but the model's terms are not accepted yet.
        case termsRequired
        case signedOut
        case unreachable
    }

    /// The account name for the stored token, or nil when it is invalid.
    static func whoAmI(session: URLSession = .shared) async -> String? {
        guard let token else { return nil }
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/whoami-v2")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    /// Whether the signed-in account may download `repo` (probes its
    /// config.json without fetching any weights).
    static func access(to repo: String, file: String = "config.json", session: URLSession = .shared) async -> AccessState {
        var request = URLRequest(url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        return accessState(statusCode: http.statusCode, hasToken: hasToken)
    }

    static func accessState(statusCode: Int, hasToken: Bool) -> AccessState {
        switch statusCode {
        case 200..<400: return .granted
        case 401: return hasToken ? .termsRequired : .signedOut
        case 403: return .termsRequired
        default: return .unreachable
        }
    }

    static func modelPageURL(_ repo: String) -> URL { URL(string: "https://huggingface.co/\(repo)")! }
    static let tokenSettingsURL = URL(string: "https://huggingface.co/settings/tokens")!
}
