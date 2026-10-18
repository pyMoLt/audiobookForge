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

    var body: some View {
        @Bindable var settingsStore = settingsStore
        Form {
            Section("Status") {
                ForEach(statuses) { status in
                    HStack(alignment: .top) {
                        Image(systemName: icon(for: status))
                            .foregroundStyle(color(for: status))
                        VStack(alignment: .leading) {
                            Text(status.name).font(.body.weight(.medium))
                            Text(detail(for: status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if status.id == "ffmpeg", case .missing = status.state {
                            Button("Befehl kopieren") {
                                copyToClipboard("brew install ffmpeg")
                            }
                            .font(.caption)
                        }
                    }
                }
                Button {
                    refreshStatuses()
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Erneut prüfen")
                    }
                }
                .disabled(isChecking)
            }

            Section("Kokoro-Umgebung einrichten") {
                Text("Erstellt eine eigene Python-Umgebung unter \(bridge.bridgeDirectory.path) und installiert mlx-audio, misaki und soundfile. Beim ersten Lauf werden zusätzlich die Kokoro-Modellgewichte heruntergeladen (~300 MB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    runSetup()
                } label: {
                    if isRunningSetup {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Einrichten / reparieren")
                    }
                }
                .disabled(isRunningSetup)

                if !setupLog.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(setupLog.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .padding(8)
                    .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Section("Piper-Umgebung einrichten") {
                Text("Erstellt eine eigene, schlanke Python-Umgebung unter \(piper.directory.path) und installiert piper-tts. Stimmen (z. B. Thorsten) werden separat unter „TTS-Engine“ heruntergeladen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    runPiperSetup()
                } label: {
                    if isRunningPiperSetup {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Einrichten / reparieren")
                    }
                }
                .disabled(isRunningPiperSetup)

                if !piperSetupLog.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(piperSetupLog.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                    .padding(8)
                    .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Section("Manuelle Pfad-Overrides") {
                TextField("ffmpeg-Pfad (leer = automatisch suchen)", text: $settingsStore.settings.dependencyPathOverrides.ffmpegPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Python-Interpreter für Bridge (leer = eigene venv)", text: $settingsStore.settings.dependencyPathOverrides.bridgePythonPath)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStatuses() }
    }

    private func refreshStatuses() {
        isChecking = true
        Task {
            let ffmpeg = DependencyChecker.checkFFmpeg(settings: settingsStore.settings)
            let kokoro = DependencyChecker.checkBridge(bridge: bridge)
            let piperStatus = DependencyChecker.checkPiper(environment: piper)
            let germanKokoroStatus = DependencyChecker.checkGermanKokoro(environment: germanKokoro)
            let supertonicStatus = DependencyChecker.checkSupertonic(environment: supertonic)
            let llm = await DependencyChecker.checkLLMEndpoint(settings: settingsStore.settings)
            await MainActor.run {
                statuses = [ffmpeg, kokoro, piperStatus, germanKokoroStatus, supertonicStatus, llm]
                isChecking = false
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
