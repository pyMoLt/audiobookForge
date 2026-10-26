import SwiftUI
import AppKit

struct DiagnosticsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore
    private let bridge = BridgeEnvironmentManager.shared
    private let piper = PiperEnvironmentManager.shared
    private let germanKokoro = GermanKokoroEnvironmentManager.shared
    private let supertonic = SupertonicEnvironmentManager.shared

    @State private var statuses: [DependencyStatus] = []
    @State private var isRunningSetup = false
    @State private var setupLog: [String] = []
    @State private var isRunningPiperSetup = false
    @State private var piperSetupLog: [String] = []
    @State private var isChecking = false
    @State private var storageItems: [StorageItem] = []
    @State private var isCalculatingStorage = false
    @State private var itemToClean: StorageItem?
    @State private var showCleanAllConfirmation = false

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillRow(title: "Einrichtungsassistent", subtitle: "Kokoro, erste Stimmen und lokale KI Schritt für Schritt einrichten.", systemImage: "wand.and.stars") {
                Button("Öffnen") { NotificationCenter.default.post(name: .openSetupAssistant, object: nil) }
                    .buttonStyle(.flowProminent)
            }
            PillSection("Zustand") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(statuses) { status in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(for: status))
                                .foregroundStyle(color(for: status))
                                .font(.system(size: 16))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.name).flowFont(.body, weight: .medium)
                                Text(detail(for: status))
                                    .flowFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if status.id == "ffmpeg", case .missing = status.state {
                                Button("Befehl kopieren") { copyToClipboard("brew install ffmpeg") }
                                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    Button {
                        refreshStatuses()
                    } label: {
                        if isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Erneut prüfen", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                    .disabled(isChecking)
                    .padding(.top, 8)
                }
                .padding(18)
                .flowSurface(cornerRadius: Theme.Radius.card)
            }

            PillSection("Speicher-Übersicht & Aufräumen") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(storageItems) { item in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: item.isEssential ? "shippingbox.fill" : "archivebox")
                                .foregroundStyle(item.isEssential ? Color.secondary : Color.accentColor)
                                .font(.system(size: 16))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).flowFont(.body, weight: .medium)
                                Text(item.directory.path)
                                    .flowFont(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(item.formattedSize)
                                .flowFont(.callout, weight: .semibold)
                                .foregroundStyle(.secondary)
                            Button("Leeren …") {
                                itemToClean = item
                            }
                            .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                            .disabled(item.byteCount == 0)
                        }
                        .padding(.vertical, 8)
                        if item.id != storageItems.last?.id {
                            Divider().opacity(0.4)
                        }
                    }

                    HStack {
                        Button {
                            refreshStorage()
                        } label: {
                            if isCalculatingStorage {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Größen neu berechnen", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                        .disabled(isCalculatingStorage)

                        Spacer()

                        Button("Caches aufräumen") {
                            showCleanAllConfirmation = true
                        }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                    }
                    .padding(.top, 12)
                }
                .padding(18)
                .flowSurface(cornerRadius: Theme.Radius.card)
            }

            setupCard(
                title: "Kokoro einrichten",
                note: String(localized: "Eigene Python-Umgebung unter \((bridge.bridgeDirectory.path as NSString).abbreviatingWithTildeInPath) mit mlx-audio, misaki und soundfile. Beim ersten Vorlesen kommen die Modellgewichte (~300 MB) dazu."),
                isRunning: isRunningSetup, log: setupLog, action: runSetup)

            setupCard(
                title: "Piper einrichten",
                note: String(localized: "Schlanke Python-Umgebung unter \((piper.directory.path as NSString).abbreviatingWithTildeInPath) mit piper-tts. Stimmen werden einzeln unter „Engines & Downloads“ geladen."),
                isRunning: isRunningPiperSetup, log: piperSetupLog, action: runPiperSetup)

            PillSection("Pfade") {
                PillRow(title: "ffmpeg", subtitle: "Leer = automatisch suchen") {
                    TextField("/opt/homebrew/bin/ffmpeg", text: $store.settings.dependencyPathOverrides.ffmpegPath)
                        .textFieldStyle(.flow)
                        .frame(width: 260)
                }
                PillRow(title: "Python für Kokoro", subtitle: "Leer = eigene Umgebung") {
                    TextField("—", text: $store.settings.dependencyPathOverrides.bridgePythonPath)
                        .textFieldStyle(.flow)
                        .frame(width: 260)
                }
            }

        }
        .confirmationDialog(
            "Möchtest du den Posten „\(itemToClean?.name ?? "")“ wirklich leeren?",
            isPresented: Binding(get: { itemToClean != nil }, set: { if !$0 { itemToClean = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unwiderruflich leeren", role: .destructive) {
                if let item = itemToClean {
                    try? StorageReportService.shared.clean(item: item)
                    refreshStorage()
                }
                itemToClean = nil
            }
            Button("Abbrechen", role: .cancel) { itemToClean = nil }
        } message: {
            Text("Dateien in diesem Cache-Ordner werden gelöscht. Bei Laufzeitumgebungen müssen die Pakete beim nächsten Mal neu geladen werden.")
        }
        .confirmationDialog(
            "Alle temporären Caches leeren?",
            isPresented: $showCleanAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Caches leeren", role: .destructive) {
                try? StorageReportService.shared.cleanAllNonEssential()
                refreshStorage()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Kapitel-Audio-Zwischenspeicher, Verarbeitungsprotokolle und temporäre Sicherungen werden geleert. Deine Bücher und Einstellungen bleiben erhalten.")
        }
        .onAppear {
            if statuses.isEmpty { refreshStatuses() }
            if storageItems.isEmpty { refreshStorage() }
        }
    }

    private func refreshStorage() {
        guard !isCalculatingStorage else { return }
        isCalculatingStorage = true
        Task {
            let report = await StorageReportService.shared.fetchReport()
            await MainActor.run {
                self.storageItems = report
                self.isCalculatingStorage = false
            }
        }
    }


    private func setupCard(title: String, note: String, isRunning: Bool, log: [String], action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L(title)).flowFont(.body, weight: .semibold)
                Spacer()
                Button(action: action) {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Einrichten / reparieren", systemImage: "wrench.and.screwdriver")
                    }
                }
                .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                .disabled(isRunning)
            }
            Text(note).flowFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !log.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(18)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }

    private func refreshStatuses() {
        guard !isChecking else { return }
        isChecking = true
        let settings = settingsStore.settings
        let bridge = self.bridge
        let piper = self.piper
        let germanKokoro = self.germanKokoro
        let supertonic = self.supertonic
        Task.detached(priority: .utility) {
            let ffmpeg = DependencyChecker.checkFFmpeg(settings: settings)
            let python = DependencyChecker.checkPython()
            let kokoro = DependencyChecker.checkBridge(bridge: bridge)
            let piperStatus = DependencyChecker.checkPiper(environment: piper)
            let germanKokoroStatus = DependencyChecker.checkGermanKokoro(environment: germanKokoro)
            let supertonicStatus = DependencyChecker.checkSupertonic(environment: supertonic)
            let omniVoice = DependencyChecker.checkOmniVoice(environment: OmniVoiceEnvironmentManager.shared)
            let systemVoices = DependencyChecker.checkSystemVoices()
            let phonon = DependencyChecker.checkPhonon()
            let pocket = DependencyChecker.checkPocket()
            let llm = await DependencyChecker.checkLLMEndpoint(settings: settings)
            await MainActor.run {
                self.statuses = [ffmpeg, python, kokoro, piperStatus, germanKokoroStatus, supertonicStatus, phonon, pocket, omniVoice, systemVoices, llm]
                self.isChecking = false
            }
        }
    }

    private func runPiperSetup() {
        isRunningPiperSetup = true
        piperSetupLog = []
        Task {
            do {
                try await piper.runSetup { line in
                    Task { @MainActor in piperSetupLog.append(line) }
                }
                await MainActor.run {
                    isRunningPiperSetup = false
                    refreshStatuses()
                }
            } catch {
                await MainActor.run {
                    piperSetupLog.append("FEHLER: \(error.localizedDescription)")
                    isRunningPiperSetup = false
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runSetup() {
        isRunningSetup = true
        setupLog = []
        Task {
            do {
                try await bridge.runSetup { line in
                    Task { @MainActor in
                        setupLog.append(line)
                    }
                }
                await MainActor.run {
                    isRunningSetup = false
                    refreshStatuses()
                }
            } catch {
                await MainActor.run {
                    setupLog.append("FEHLER: \(error.localizedDescription)")
                    isRunningSetup = false
                }
            }
        }
    }

    private func icon(for status: DependencyStatus) -> String {
        switch status.state {
        case .ok: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: DependencyStatus) -> Color {
        switch status.state {
        case .ok: return .green
        case .missing: return .orange
        }
    }

    private func detail(for status: DependencyStatus) -> String {
        switch status.state {
        case .ok(let detail): return detail
        case .missing(let reason): return reason
        }
    }
}
