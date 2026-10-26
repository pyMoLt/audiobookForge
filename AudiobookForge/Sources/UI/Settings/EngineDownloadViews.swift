import SwiftUI
import AppKit

/// Display name of a language code in the app language.
func languageDisplayName(_ code: String) -> String {
    switch code {
    case "de": return L("Deutsch")
    case "en": return L("Englisch")
    case "fr": return L("Französisch")
    case "es": return L("Spanisch")
    case "it": return L("Italienisch")
    case "pt": return L("Portugiesisch")
    default: return code.uppercased()
    }
}

// MARK: - Hugging Face account

/// One sign-in for every gated model (Phonon 40m, Pocket TTS): a read
/// token, kept in the keychain. Each model's terms are accepted once on
/// its Hugging Face page (per account, so also on other Macs).
struct HuggingFaceAccountCard: View {
    @State private var tokenInput = ""
    @State private var accountName: String?
    @State private var checking = false
    @State private var message: String?
    @State private var hasToken = HuggingFaceAccount.hasToken

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Hugging-Face-Konto").flowFont(.body, weight: .medium)
                Spacer()
                if checking {
                    ProgressView().controlSize(.small)
                } else if let accountName {
                    StatusBadge(text: L("Angemeldet als") + " \(accountName)", systemImage: "checkmark.circle.fill", tint: .green)
                } else if hasToken {
                    StatusBadge(text: L("Token ungültig"), systemImage: "exclamationmark.triangle.fill", tint: .orange)
                } else {
                    StatusBadge(text: L("Nicht angemeldet"), systemImage: "person.crop.circle.badge.questionmark", tint: .secondary)
                }
            }
            Text("Einige Modelle (Phonon 40m, Pocket TTS) gibt es erst nach Zustimmung zu ihren Nutzungsbedingungen. Lege auf Hugging Face ein Lese-Token an und füge es hier ein; es wird im Schlüsselbund gespeichert. Die Zustimmung gibst du je Modell einmal auf seiner Seite — sie gilt für dein Konto, also auch auf anderen Macs.")
                .flowFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField(L("hf_… Lese-Token"), text: $tokenInput)
                    .textFieldStyle(.flow)
                    .frame(maxWidth: 300)
                Button("Speichern") { save() }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                    .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Token erstellen") { NSWorkspace.shared.open(HuggingFaceAccount.tokenSettingsURL) }
                    .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                if HuggingFaceAccount.tokenSource == L("Schlüsselbund") {
                    Button("Abmelden") { signOut() }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                }
            }
            if let source = HuggingFaceAccount.tokenSource {
                Text(L("Token-Quelle:") + " \(source)").flowFont(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
        .task { await refresh() }
    }

    private func refresh() async {
        hasToken = HuggingFaceAccount.hasToken
        guard hasToken else { accountName = nil; return }
        checking = true
        accountName = await HuggingFaceAccount.whoAmI()
        checking = false
    }

    private func save() {
        do {
            try HuggingFaceAccount.save(tokenInput)
            tokenInput = ""
            message = nil
            Task { await refresh(); NotificationCenter.default.post(name: .huggingFaceAccountChanged, object: nil) }
        } catch {
            message = L("Token konnte nicht im Schlüsselbund gespeichert werden.")
        }
    }

    private func signOut() {
        HuggingFaceAccount.delete()
        Task { await refresh(); NotificationCenter.default.post(name: .huggingFaceAccountChanged, object: nil) }
    }
}

extension Notification.Name {
    static let huggingFaceAccountChanged = Notification.Name("AudiobookForge.huggingFaceAccountChanged")
}

// MARK: - Gated model row

/// One downloadable, gated language model: access state, size, install /
/// remove, progress.
struct GatedModelRow: View {
    let title: String
    let detail: String
    let repo: String
    let isInstalled: () -> Bool
    let install: (@escaping @Sendable (String) -> Void) async throws -> Void
    let remove: () throws -> Void

    @State private var installed = false
    @State private var access: HuggingFaceAccount.AccessState?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).flowFont(.callout, weight: .medium)
                Text(verbatim: message ?? detail).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if installed {
                StatusBadge(text: L("Bereit"), systemImage: "checkmark.circle.fill", tint: .green)
                Button("Entfernen") { delete() }
                    .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
            } else if working {
                ProgressView().controlSize(.small)
            } else if access == .termsRequired || access == .signedOut {
                Button(access == .signedOut ? L("Anmelden nötig") : L("Lizenz akzeptieren")) {
                    NSWorkspace.shared.open(HuggingFaceAccount.modelPageURL(repo))
                }
                .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                Button("Laden") { start() }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            } else {
                Button("Laden") { start() }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .huggingFaceAccountChanged)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        installed = isInstalled()
        if !installed { access = await HuggingFaceAccount.access(to: repo) }
    }

    private func start() {
        working = true
        message = L("Starte Download …")
        Task {
            do {
                try await install { line in
                    let text = line.hasPrefix("STEP ") ? String(line.dropFirst(5)) : line
                    guard !line.hasPrefix("PROGRESS ") else { return }
                    Task { @MainActor in message = text }
                }
                message = nil
            } catch {
                message = error.localizedDescription
            }
            working = false
            await refresh()
        }
    }

    private func delete() {
        do { try remove(); message = L("Entfernt.") } catch { message = error.localizedDescription }
        installed = isInstalled()
    }
}

// MARK: - Phonon

struct PhononModelsCard: View {
    private let environment = PhononEnvironmentManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Phonon — Sprachmodelle").flowFont(.body, weight: .medium)
            ForEach(PhononEnvironmentManager.languages, id: \.self) { language in
                let voices = PhononVoice.catalog.filter { $0.language == language }.count
                GatedModelRow(
                    title: languageDisplayName(language),
                    detail: String(format: L("Phonon 40m · ~78 MB · %d Stimmen · CC BY-NC 4.0"), voices),
                    repo: PhononEnvironmentManager.repo(for: language),
                    isInstalled: { environment.isReady(language: language) },
                    install: { onLine in try await environment.installModel(language, onOutput: onLine) },
                    remove: { try environment.removeModel(language) }
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Pocket TTS

struct PocketModelsCard: View {
    private let environment = PocketEnvironmentManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pocket TTS — Sprachmodelle").flowFont(.body, weight: .medium)
            ForEach(PocketEnvironmentManager.languages, id: \.self) { language in
                ForEach([false, true], id: \.self) { high in
                    GatedModelRow(
                        title: languageDisplayName(language) + (high ? " · " + L("Hohe Qualität (24 Schichten)") : ""),
                        detail: high ? L("~700 MB · langsamer, natürlicher · CC BY 4.0") : L("~220 MB · schnell · CC BY 4.0"),
                        repo: PocketEnvironmentManager.repo,
                        isInstalled: { environment.isReady(language: language, highQuality: high) },
                        install: { onLine in try await environment.installModel(language, highQuality: high, onOutput: onLine) },
                        remove: { try environment.removeModel(language, highQuality: high) }
                    )
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Overview

/// Every engine at a glance (v4): installed or not, what is still missing,
/// and the one-click runtime setup where an engine needs one. Models and
/// voices follow in the engine sections below.
struct EngineOverviewCard: View {
    private struct Row: Identifiable, Sendable {
        let id: TTSEngineID
        let ready: Bool
        let detail: String
        let setup: (@Sendable (@escaping @Sendable (String) -> Void) async throws -> Void)?
    }

    @State private var rows: [Row] = []
    @State private var working: TTSEngineID?
    @State private var message: [TTSEngineID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: row.ready ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(row.ready ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.id.shortName).flowFont(.callout, weight: .medium)
                        Text(verbatim: message[row.id] ?? row.detail).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if working == row.id {
                        ProgressView().controlSize(.small)
                    } else if !row.ready, let setup = row.setup {
                        Button("Einrichten") { run(row.id, setup) }
                            .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                            .disabled(working != nil)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
        .task { await refresh() }
    }

    private func refresh() async {
        rows = await Task.detached(priority: .utility) { Self.probe() }.value
    }

    private typealias Setup = @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void

    nonisolated private static func languages(_ codes: [String]) -> String {
        codes.isEmpty ? L("keine Sprachmodelle") : codes.map { $0.uppercased() }.joined(separator: ", ")
    }

    nonisolated private static func probe() -> [Row] {
        let bridge = BridgeEnvironmentManager.shared
        let piper = PiperEnvironmentManager.shared
        let phonon = PhononEnvironmentManager.shared
        let pocket = PocketEnvironmentManager.shared
        let german = ["martin", "victoria", "thorsten"].filter { GermanKokoroEnvironmentManager.shared.isVoiceReady($0) }
        let phononSetup: Setup = { onLine in try await phonon.setupEnvironment(onOutput: onLine) }
        let pocketSetup: Setup = { onLine in try await pocket.setupEnvironment(onOutput: onLine) }
        let kokoroSetup: Setup = { onLine in try await bridge.runSetup(onOutput: onLine) }
        let piperSetup: Setup = { onLine in try await piper.runSetup(onOutput: onLine) }
        var rows: [Row] = []
        let phononReady = phonon.isEnvironmentReady()
        rows.append(Row(id: .phonon, ready: phononReady && !phonon.installedLanguages.isEmpty,
                        detail: phononReady ? languages(phonon.installedLanguages) : L("Laufzeit fehlt (~25 MB)"),
                        setup: phononReady ? nil : phononSetup))
        let pocketReady = pocket.isEnvironmentReady()
        rows.append(Row(id: .pocketTTS, ready: pocketReady && !pocket.installedLanguages.isEmpty,
                        detail: pocketReady ? languages(pocket.installedLanguages) : L("Laufzeit fehlt (~900 MB, PyTorch)"),
                        setup: pocketReady ? nil : pocketSetup))
        let kokoroReady = bridge.isEnvironmentReady()
        rows.append(Row(id: .kokoro, ready: kokoroReady,
                        detail: kokoroReady ? L("EN, FR, ES, IT bereit") : L("Laufzeit fehlt (mlx-audio)"),
                        setup: kokoroReady ? nil : kokoroSetup))
        rows.append(Row(id: .kokoroGerman, ready: !german.isEmpty,
                        detail: german.isEmpty ? L("Modelle unten laden") : german.map { $0.capitalized }.joined(separator: ", "), setup: nil))
        let piperReady = piper.isEnvironmentReady()
        rows.append(Row(id: .piper, ready: piperReady,
                        detail: piperReady ? L("Stimmen einzeln in der Galerie laden") : L("Laufzeit fehlt (piper-tts)"),
                        setup: piperReady ? nil : piperSetup))
        let supertonicReady = SupertonicEnvironmentManager.shared.isReady()
        rows.append(Row(id: .supertonic3, ready: supertonicReady, detail: supertonicReady ? L("Bereit") : L("Modell unten laden"), setup: nil))
        let omniReady = OmniVoiceEnvironmentManager.shared.isReady()
        rows.append(Row(id: .omniVoice, ready: omniReady, detail: omniReady ? L("Bereit") : L("Modell unten laden (2 GB)"), setup: nil))
        rows.append(Row(id: .appleSystem, ready: true, detail: String(format: L("%d Systemstimmen"), AppleSpeechEngine.installedVoices().count), setup: nil))
        return rows
    }

    private func run(_ engine: TTSEngineID, _ setup: @escaping Setup) {
        working = engine
        Task {
            do {
                try await setup { line in
                    let text = line.hasPrefix("STEP ") ? String(line.dropFirst(5)) : line
                    Task { @MainActor in message[engine] = text }
                }
                message[engine] = nil
            } catch {
                message[engine] = error.localizedDescription
            }
            working = nil
            await refresh()
        }
    }
}
