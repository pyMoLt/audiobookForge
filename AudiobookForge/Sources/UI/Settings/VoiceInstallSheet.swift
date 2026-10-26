import SwiftUI
import AppKit

/// "I like this voice — install it" (v4.2): everything a voice still needs —
/// engine runtime, language model, the voice itself — in one step, straight
/// from the gallery. Gated models (Phonon, Pocket TTS) ask for the Hugging
/// Face sign-in and the model's terms first.
struct VoiceInstallSheet: View {
    let profile: VoiceProfile
    var onInstalled: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settingsStore
    @State private var components: [EngineComponent]?
    @State private var access: HuggingFaceAccount.AccessState?
    @State private var working = false
    @State private var currentStep: Int?
    @State private var status: String?
    @State private var error: String?

    private var gatedRepo: String? { components?.compactMap(\.gatedRepo).first }
    private var totalBytes: Int64 { components?.reduce(0) { $0 + $1.sizeBytes } ?? 0 }
    private var blocked: Bool { gatedRepo != nil && access != .granted && access != .unreachable }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: L("„%@“ installieren"), profile.displayName))
                    .appFont(size: 20, weight: .semibold, design: .serif)
                Text(verbatim: profile.id.engine.shortName + " · " + profile.id.engine.license)
                    .flowFont(.caption).foregroundStyle(.secondary)
            }

            if let components {
                if components.isEmpty {
                    Label("Alles ist schon da.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                            HStack(spacing: 10) {
                                stepIcon(index)
                                Text(verbatim: component.title).flowFont(.callout)
                                Spacer(minLength: 8)
                                Text(verbatim: component.sizeText).flowFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .flowSurface(cornerRadius: Theme.Radius.row)
                    if let shared = components.first(where: { !$0.sharedBy.isEmpty }) {
                        Text(String(format: L("„%@“ nutzen auch: %@."), shared.title,
                                    shared.sharedBy.filter { $0 != profile.id.engine }.map(\.shortName).joined(separator: ", ")))
                            .flowFont(.caption).foregroundStyle(.secondary)
                    }
                }
                if let repo = gatedRepo, access != .granted {
                    gatedNotice(repo)
                }
            } else {
                ProgressView().controlSize(.small)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").flowFont(.caption).foregroundStyle(.red)
            } else if let status, working {
                Text(verbatim: status).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .regular))
                    .disabled(working)
                Button {
                    install()
                } label: {
                    if working { ProgressView().controlSize(.small) } else {
                        Text(String(format: L("Installieren (%@)"), ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)))
                    }
                }
                .buttonStyle(.flowProminent)
                .disabled(working || components?.isEmpty != false || blocked)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 720)
        .background { PaperPage() }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .huggingFaceAccountChanged)) { _ in Task { await checkAccess() } }
    }

    @ViewBuilder
    private func stepIcon(_ index: Int) -> some View {
        if let currentStep, working, index == currentStep {
            ProgressView().controlSize(.mini).frame(width: 16)
        } else if let currentStep, index < currentStep {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16)
        } else {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).frame(width: 16)
        }
    }

    @ViewBuilder
    private func gatedNotice(_ repo: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if access == .signedOut || access == nil {
                Text("Dieses Modell ist auf Hugging Face geschützt: einmal mit einem Lese-Token anmelden und den Nutzungsbedingungen zustimmen.")
                    .flowFont(.caption).foregroundStyle(.secondary)
                HuggingFaceAccountCard()
            } else if access == .termsRequired {
                Text("Noch den Nutzungsbedingungen des Modells zustimmen (einmal je Konto), dann hier erneut prüfen.")
                    .flowFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Modellseite öffnen") { NSWorkspace.shared.open(HuggingFaceAccount.modelPageURL(repo)) }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                Button("Erneut prüfen") { Task { await checkAccess() } }
                    .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
            }
        }
    }

    private func load() async {
        let voice = profile.id
        let settings = settingsStore.settings
        components = await Task.detached(priority: .userInitiated) { EngineInventory.missingComponents(for: voice, settings: settings) }.value
        await checkAccess()
    }

    private func checkAccess() async {
        guard let repo = gatedRepo else { return }
        access = await HuggingFaceAccount.access(to: repo)
    }

    private func install() {
        guard let components else { return }
        working = true
        error = nil
        currentStep = 0
        Task {
            do {
                try await ComponentRunner.install(components) { index, text in
                    currentStep = index
                    status = text
                }
                currentStep = components.count
                working = false
                onInstalled()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
