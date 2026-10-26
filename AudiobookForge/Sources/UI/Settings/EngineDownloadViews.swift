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
    /// Something was installed or removed (v4.2): inventories and the gallery refresh.
    static let engineInventoryChanged = Notification.Name("AudiobookForge.engineInventoryChanged")
}

// MARK: - Running components

/// Runs install steps and turns their output into one short status line.
enum ComponentRunner {
    static func statusLine(_ line: String) -> String? {
        if line.hasPrefix("PROGRESS "), let fraction = Double(line.dropFirst(9).trimmingCharacters(in: .whitespaces)) {
            return String(format: L("Lädt … %d %%"), Int(fraction * 100))
        }
        let text = line.hasPrefix("STEP ") ? String(line.dropFirst(5)) : line
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(text.prefix(140))
    }

    @MainActor
    static func install(_ components: [EngineComponent], onStatus: @escaping @MainActor (Int, String) -> Void) async throws {
        for (index, component) in components.enumerated() {
            guard let install = component.install else { continue }
            onStatus(index, component.title)
            // Each step up to three times (v4.2): downloads resume where they stopped.
            for attempt in 1...NetworkPolicy.attempts {
                do {
                    try await install { line in
                        guard let text = statusLine(line) else { return }
                        Task { @MainActor in onStatus(index, text) }
                    }
                    break
                } catch {
                    guard attempt < NetworkPolicy.attempts, NetworkPolicy.isRetryable(error) else { throw error }
                    onStatus(index, String(format: L("Verbindung unterbrochen — neuer Versuch (%d/%d) …"), attempt + 1, NetworkPolicy.attempts))
                    try await Task.sleep(for: .seconds(3 * attempt))
                }
            }
        }
        NotificationCenter.default.post(name: .engineInventoryChanged, object: nil)
    }

    @MainActor
    static func remove(_ component: EngineComponent) async throws {
        guard let remove = component.remove else { return }
        try await Task.detached(priority: .userInitiated) { try remove() }.value
        NotificationCenter.default.post(name: .engineInventoryChanged, object: nil)
    }
}

// MARK: - Engines & Downloads (v4.2)

/// Every engine at a glance: installed or not, runtime version, space used,
/// and — expanded — each piece (runtime, language models, voices) to load
/// or remove. Voices are best added from the gallery, where they can be
/// heard first; this is the place to see what is there and free space.
struct EngineInventoryList: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var statuses: [EngineStatus] = []
    @State private var expanded: Set<TTSEngineID> = []
    @State private var refreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if statuses.isEmpty {
                ProgressView().controlSize(.small).padding(18)
            }
            ForEach(statuses) { status in
                EngineInventoryCard(status: status, isExpanded: Binding(
                    get: { expanded.contains(status.engine) },
                    set: { if $0 { expanded.insert(status.engine) } else { expanded.remove(status.engine) } }
                ), allStatuses: statuses)
            }
        }
        .task(id: refreshToken) {
            let settings = settingsStore.settings
            statuses = await Task.detached(priority: .utility) { EngineInventory.all(settings: settings) }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: .engineInventoryChanged)) { _ in refreshToken += 1 }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
            guard let list = (note.userInfo as? [String: String])?["expandEngines"] else { return }
            expanded = Set(list.split(separator: ",").compactMap { TTSEngineID(rawValue: String($0)) })
        }
        #endif
    }
}

private struct EngineInventoryCard: View {
    let status: EngineStatus
    @Binding var isExpanded: Bool
    let allStatuses: [EngineStatus]
    @State private var working = false
    @State private var message: String?
    @State private var confirmRemoveAll = false

    private var runtime: EngineComponent? { status.components.first { $0.kind == .runtime } }
    /// Pieces only this engine uses (the shared MLX runtime stays).
    private var ownInstalled: [EngineComponent] { status.components.filter { $0.installed && $0.sharedBy.isEmpty && $0.remove != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: status.isReady ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(status.isReady ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: status.engine.shortName).flowFont(.callout, weight: .semibold)
                    Text(verbatim: message ?? summary).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if working {
                    ProgressView().controlSize(.small)
                } else if let runtime, !runtime.installed, runtime.install != nil {
                    Button("Einrichten") { setUp(runtime) }
                        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                }
                if !status.components.isEmpty {
                    Button {
                        withAnimation(.snappy) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? L("Einklappen") : L("Bestandteile zeigen"))
                }
            }
            if isExpanded {
                Label(status.engine.license, systemImage: "doc.text")
                    .flowFont(.caption).foregroundStyle(.secondary)
                ForEach(status.components) { component in
                    EngineComponentRow(component: component, sharedWithInstalled: sharedWith(component))
                }
                if !ownInstalled.isEmpty {
                    Button(role: .destructive) { confirmRemoveAll = true } label: {
                        Label(String(format: L("Alles von %@ entfernen"), status.engine.shortName), systemImage: "trash")
                    }
                    .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                    .disabled(working)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
        .confirmationDialog(String(format: L("Alles von %@ entfernen?"), status.engine.shortName), isPresented: $confirmRemoveAll) {
            Button(String(format: L("%@ freigeben"), ByteCountFormatter.string(fromByteCount: ownInstalled.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file)), role: .destructive) { removeAll() }
        } message: {
            Text(String(format: L("Entfernt %@. Bücher mit diesen Stimmen lassen sich danach erst wieder vertonen, wenn du sie neu lädst."),
                        ownInstalled.map(\.title).joined(separator: ", ")))
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let version = status.version { parts.append(L("Version") + " " + version) }
        if status.engine == .appleSystem {
            parts.append(String(format: L("%d Systemstimmen"), AppleSpeechEngine.installedVoices().count))
        } else if !status.components.contains(where: { $0.installed && $0.sharedBy.isEmpty }) {
            parts.append(L("Nicht installiert"))
        } else {
            parts.append(ByteCountFormatter.string(fromByteCount: status.installedBytes, countStyle: .file)
                         + (status.usesSharedRuntime ? " " + L("+ geteilte MLX-Laufzeit") : ""))
            let payload = status.components.filter { $0.kind == .model || $0.kind == .voice }
            if !payload.isEmpty {
                parts.append(String(format: L("%d von %d geladen"), payload.filter(\.installed).count, payload.count))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Other engines that are set up and need this shared piece.
    private func sharedWith(_ component: EngineComponent) -> [TTSEngineID] {
        component.sharedBy.filter { engine in
            engine != status.engine && allStatuses.first { $0.engine == engine }?.components.contains { $0.installed && $0.kind != .runtime } == true
        }
    }

    private func setUp(_ runtime: EngineComponent) {
        working = true
        Task {
            do {
                try await ComponentRunner.install([runtime]) { _, text in message = text }
                message = nil
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }

    private func removeAll() {
        working = true
        Task {
            for component in ownInstalled {
                do { try await ComponentRunner.remove(component) } catch { message = error.localizedDescription }
            }
            working = false
        }
    }
}

/// One piece: size, state, load (with the Hugging Face sign-in where the
/// model is gated) or remove.
private struct EngineComponentRow: View {
    let component: EngineComponent
    let sharedWithInstalled: [TTSEngineID]
    @State private var working = false
    @State private var message: String?
    @State private var access: HuggingFaceAccount.AccessState?
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(component.installed ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: component.title).flowFont(.callout)
                Text(verbatim: message ?? detail).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if working {
                ProgressView().controlSize(.small)
            } else if component.installed {
                if component.remove != nil {
                    Button("Entfernen") { confirmRemove = true }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                }
            } else if component.install != nil {
                if let repo = component.gatedRepo, access == .signedOut || access == .termsRequired {
                    Button(access == .signedOut ? L("Anmelden nötig") : L("Lizenz akzeptieren")) {
                        NSWorkspace.shared.open(HuggingFaceAccount.modelPageURL(repo))
                    }
                    .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                }
                Button("Laden") { install() }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            }
        }
        .padding(.leading, 6)
        .task(id: component.installed) {
            if !component.installed, let repo = component.gatedRepo { access = await HuggingFaceAccount.access(to: repo) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .huggingFaceAccountChanged)) { _ in
            Task { if let repo = component.gatedRepo { access = await HuggingFaceAccount.access(to: repo) } }
        }
        .confirmationDialog(String(format: L("„%@“ entfernen?"), component.title), isPresented: $confirmRemove) {
            Button(String(format: L("%@ freigeben"), component.sizeText), role: .destructive) { remove() }
        } message: {
            if !sharedWithInstalled.isEmpty {
                Text(String(format: L("Wird auch von %@ gebraucht — diese Engines funktionieren danach erst wieder nach dem Einrichten."),
                            sharedWithInstalled.map(\.shortName).joined(separator: ", ")))
            }
        }
    }

    private var icon: String {
        switch component.kind {
        case .runtime: return "shippingbox"
        case .model: return "cube"
        case .voice: return "person.wave.2"
        case .neural: return "bolt.horizontal"
        }
    }

    private var detail: String {
        var parts = [component.sizeText]
        parts.append(component.installed ? L("installiert") : L("nicht geladen"))
        if component.gatedRepo != nil && !component.installed { parts.append(L("Hugging-Face-Anmeldung")) }
        return parts.joined(separator: " · ")
    }

    private func install() {
        working = true
        Task {
            do {
                try await ComponentRunner.install([component]) { _, text in message = text }
                message = nil
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }

    private func remove() {
        working = true
        Task {
            do { try await ComponentRunner.remove(component); message = nil } catch { message = error.localizedDescription }
            working = false
        }
    }
}
