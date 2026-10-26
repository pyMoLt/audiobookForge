import SwiftUI
import AppKit

/// First-launch setup (v3.1): everything the app needs is set up from here —
/// no Terminal. Language → requirements → Kokoro (+ German voices) → first
/// voices → optional local AI → done. Further engines and voices can be
/// downloaded later under Settings → Engines & Downloads.
///
/// Shown automatically while Kokoro isn't set up; reopenable from the
/// Diagnose settings page.
struct SetupAssistantView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.flowAccent) private var accent

    enum Step: Int, CaseIterable {
        case welcome, requirements, engine, voices, ai, done

        var title: String {
            switch self {
            case .welcome: return L("Willkommen")
            case .requirements: return L("Voraussetzungen")
            case .engine: return L("Sprach-Engine")
            case .voices: return L("Erste Stimmen")
            case .ai: return L("Lokale KI")
            case .done: return L("Fertig")
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var forward = true

    // Requirements
    @State private var ffmpegOK: Bool?
    @State private var pythonOK: Bool?
    @State private var isAutoInstalling = false
    @State private var autoInstallProgress = 0.0
    @State private var autoInstallStatus = ""
    @State private var autoInstallError: String?

    // Engine setup
    @State private var installGerman = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
    @State private var isInstalling = false
    @State private var installLog: [String] = []
    @State private var installError: String?
    @State private var kokoroReady = BridgeEnvironmentManager.shared.isEnvironmentReady()
    @State private var germanReady = GermanKokoroEnvironmentManager.shared.isVoiceReady("martin")

    // AI
    @State private var aiStatus: String?
    @State private var aiReachable = false

    @StateObject private var preview = VoicePreviewPlayer()

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 760, height: 620)
        .background { PaperPage() }
        .task { await checkRequirements() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
            if let raw = (note.userInfo as? [String: String])?["setupStep"], let value = Int(raw), let target = Step(rawValue: value) {
                step = target
            }
        }
        #endif
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            AppIconTile(systemImage: "books.vertical.fill", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("AudiobookForge einrichten")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                Text("Kapitel \(step.rawValue + 1) von \(Step.allCases.count) · \(step.title)")
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                    .tracking(0.8)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: s == step ? 22 : 8, height: 8)
                }
            }
            .animation(Theme.Motion.flow, value: step)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Zurück") { go(-1) }
                    .buttonStyle(.flowSubtle)
                    .disabled(isInstalling)
            }
            Spacer()
            if step == .done {
                Button("Los geht's") { finish() }
                    .buttonStyle(FlowButtonStyle(variant: .prominent, size: .large))
                    .keyboardShortcut(.defaultAction)
            } else {
                if step == .ai || (step == .engine && !kokoroReady) {
                    Button("Überspringen") { go(1) }
                        .buttonStyle(.flowSubtle)
                        .disabled(isInstalling)
                }
                Button("Weiter") { go(1) }
                    .buttonStyle(FlowButtonStyle(variant: .prominent, size: .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isInstalling || (step == .voices && !kokoroReady))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { step = next }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: SetupAssistantView.completedKey)
        preview.stop()
        dismiss()
    }

    static let completedKey = "setup.completed.v31"

    /// Show automatically on launch while Kokoro isn't usable yet.
    static var shouldShowAutomatically: Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return !BridgeEnvironmentManager.shared.isEnvironmentReady()
            || !UserDefaults.standard.bool(forKey: completedKey)
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch step {
                case .welcome: welcomePage
                case .requirements: requirementsPage
                case .engine: enginePage
                case .voices: voicesPage
                case .ai: aiPage
                case .done: donePage
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var welcomePage: some View {
        @Bindable var store = settingsStore
        return VStack(alignment: .leading, spacing: 20) {
            Text("Aus jedem PDF und EPUB wird ein Hörbuch — komplett lokal auf deinem Mac.")
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Text("In wenigen Schritten richten wir eine Sprach-Engine und deine ersten Stimmen ein. Alles Weitere kannst du später in den Einstellungen nachladen.")
                .flowFont(.body)
                .foregroundStyle(.secondary)
            PillRow(title: "App-Sprache", subtitle: "Wird nach einem Neustart vollständig übernommen.") {
                SegmentedPills(selection: $store.settings.appLanguage, options: [
                    PillOption(value: AppLanguage.system, label: "System", systemImage: "globe"),
                    PillOption(value: AppLanguage.de, label: "Deutsch", verbatim: true),
                    PillOption(value: AppLanguage.en, label: "English", verbatim: true),
                ])
            }
            .onChange(of: settingsStore.settings.appLanguage) { _, language in language.apply() }
            PillRow(title: "Akzentfarbe") {
                HStack(spacing: 8) {
                    ForEach(AppAccent.allCases.filter { $0 != .system }) { candidate in
                        Circle()
                            .fill(candidate.fill)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(candidate == settingsStore.settings.accent ? 0.6 : 0), lineWidth: 2).padding(-3))
                            .onTapGesture { settingsStore.settings.accent = candidate }
                            .help(candidate.displayName)
                    }
                }
            }
        }
    }

    private var requirementsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Zwei Werkzeuge braucht die App auf deinem Mac.")
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text("AudiobookForge kann diese automatisch als eigenständige Laufzeit herunterladen — ohne Homebrew oder Terminal.")
                .flowFont(.body)
                .foregroundStyle(.secondary)

            requirementRow(
                title: "ffmpeg",
                detail: "Verpackt die Kapitel zu einem Hörbuch (M4B/MP3).",
                ok: ffmpegOK, command: "brew install ffmpeg")
            requirementRow(
                title: "Python 3.11 oder 3.12",
                detail: "Laufzeit für die lokalen Sprachmodelle (Kokoro über MLX).",
                ok: pythonOK, command: "brew install python@3.12")

            if ffmpegOK == false || pythonOK == false {
                if isAutoInstalling {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(autoInstallStatus.isEmpty ? "Laufzeit wird eingerichtet …" : autoInstallStatus)
                                .flowFont(.callout, weight: .medium)
                        }
                        ProgressView(value: autoInstallProgress, total: 1.0)
                            .tint(accent.color)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .flowSurface(cornerRadius: Theme.Radius.row)
                } else {
                    Button {
                        Task { await autoInstallRuntime() }
                    } label: {
                        Label("Automatisch einrichten (empfohlen)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(FlowButtonStyle(variant: .prominent, size: .large))
                }

                if let autoInstallError {
                    Text(autoInstallError)
                        .flowFont(.caption)
                        .foregroundStyle(.red)
                }

                DisclosureGroup("Alternative: Manuelle Installation über Homebrew") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Befehle kopieren, im Terminal ausführen (brew.sh) und danach „Erneut prüfen“ klicken:")
                            .flowFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .flowFont(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                Task { await checkRequirements() }
            } label: {
                Label("Erneut prüfen", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.flowSecondary)
            .disabled(isAutoInstalling)
        }
    }

    private func requirementRow(title: String, detail: String, ok: Bool?, command: String) -> some View {
        HStack(spacing: 14) {
            Group {
                switch ok {
                case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .some(false): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .none: ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 20))
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).flowFont(.body, weight: .semibold)
                Text(L(detail)).flowFont(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if ok == false {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Label(command, systemImage: "doc.on.doc")
                        .font(.system(size: 12, design: .monospaced))
                }
                .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                .help("Befehl kopieren")
            }
        }
        .padding(16)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }

    private var enginePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kokoro — schnelle, natürliche Stimmen")
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text("Kokoro läuft über MLX direkt auf dem Apple-Chip. Die App legt dafür eine eigene Python-Umgebung an und lädt beim ersten Vorlesen die Modellgewichte (~300 MB).")
                .flowFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                statusChip(kokoroReady ? "Kokoro bereit" : "Kokoro nicht eingerichtet", ok: kokoroReady)
                if installGerman || germanReady {
                    statusChip(germanReady ? "Deutsche Stimmen bereit" : "Deutsche Stimmen ausstehend", ok: germanReady)
                }
            }
            PillRow(title: "Deutsche Stimmen mitinstallieren", subtitle: "Martin und Victoria (Kokoro Deutsch, ~350 MB).") {
                PillToggle(isOn: $installGerman)
            }
            .disabled(isInstalling || germanReady)

            Button {
                Task { await install() }
            } label: {
                if isInstalling {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Wird eingerichtet …") }
                } else {
                    Label(kokoroReady && (!installGerman || germanReady) ? "Erneut prüfen / reparieren" : "Jetzt einrichten", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(FlowButtonStyle(variant: kokoroReady ? .secondary : .prominent, size: .large))
            .disabled(isInstalling || pythonOK == false)

            if let installError {
                Label(installError, systemImage: "exclamationmark.triangle.fill")
                    .flowFont(.callout)
                    .foregroundStyle(.red)
            }
            if !installLog.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(installLog.suffix(200).enumerated()), id: \.offset) { index, line in
                                Text(line).font(.system(size: 11, design: .monospaced)).id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .onChange(of: installLog.count) { _, count in proxy.scrollTo(min(count, 200) - 1) }
                }
            }
        }
    }

    private func statusChip(_ text: String, ok: Bool) -> some View {
        StatusBadge(text: text, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed", tint: ok ? .green : .secondary)
    }

    private var voicesPage: some View {
        @Bindable var store = settingsStore
        let english = VoiceCatalog.allProfiles.filter { $0.id.engine == .kokoro && $0.languageCode.hasPrefix("en") && $0.featured }
        let german = VoiceCatalog.allProfiles.filter { ($0.id.engine == .kokoroGerman) && $0.languageCode.hasPrefix("de") }
        return VStack(alignment: .leading, spacing: 16) {
            Text("Wer liest deine Bücher vor?")
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text("Tippe auf ▶ für eine Hörprobe und wähle je Sprache eine Stimme. Weitere Stimmen findest du später in der Sprecherkartei.")
                .flowFont(.body)
                .foregroundStyle(.secondary)
            voiceGroup(title: "Englisch", profiles: english, selection: $store.settings.defaultVoiceEN)
            if germanReady {
                voiceGroup(title: "Deutsch", profiles: german, selection: $store.settings.defaultVoiceDE)
            }
            if let error = preview.errorMessage {
                Text(error).flowFont(.caption).foregroundStyle(.red)
            }
        }
    }

    private func voiceGroup(title: String, profiles: [VoiceProfile], selection: Binding<VoiceID>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title))
                .flowFont(.caption, weight: .semibold)
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .tracking(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(profiles) { profile in
                    let selected = selection.wrappedValue == profile.id
                    HStack(spacing: 10) {
                        Button {
                            let settings = settingsStore.settings
                            preview.toggle(text: profile.sampleText, engineID: profile.id.engine, voice: profile.id.voice,
                                           speed: settings.defaultSpeed(for: profile.id.engine), settings: settings)
                        } label: {
                            Image(systemName: preview.currentVoiceID == profile.id && (preview.isPlaying || preview.isGenerating) ? "stop.fill" : "play.fill")
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName).flowFont(.body, weight: .semibold)
                            Text(profile.gender.label).flowFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .padding(10)
                    .flowSurface(cornerRadius: 14)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection.wrappedValue = profile.id }
                }
            }
        }
    }

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Zusammenfassungen und Bildbeschreibungen (optional)")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Text("Für Zusammenfassungen und das Beschreiben von Abbildungen nutzt die App ein lokales Sprachmodell über oMLX oder LM Studio. Zum reinen Vorlesen ist das nicht nötig.")
                .flowFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    Task { await checkAI() }
                } label: {
                    Label("Lokalen Server suchen", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.flowSecondary)
                if let aiStatus {
                    StatusBadge(text: aiStatus, systemImage: aiReachable ? "checkmark.circle.fill" : "xmark.circle", tint: aiReachable ? .green : .secondary)
                }
            }
            Text("Einstellungen → KI & Zusammenfassung — dort lassen sich Server und Modell jederzeit ändern.")
                .flowFont(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var donePage: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Dein Regal ist bereit.")
                .font(.system(size: 28, weight: .semibold, design: .serif))
            Text("Zieh ein PDF oder EPUB ins Fenster. Weitere Stimmen und Engines (Phonon, Pocket TTS, Piper, Supertonic, eigene Stimmen) lädst du jederzeit unter Einstellungen → Engines & Downloads.")
                .flowFont(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func checkRequirements() async {
        let settings = settingsStore.settings
        let result = await Task.detached(priority: .userInitiated) { () -> (Bool, Bool) in
            let ffmpeg: Bool = { if case .ok = DependencyChecker.checkFFmpeg(settings: settings).state { return true } else { return false } }()
            let python: Bool = { if case .ok = DependencyChecker.checkPython().state { return true } else { return false } }()
            return (ffmpeg, python)
        }.value
        ffmpegOK = result.0
        pythonOK = result.1
    }

    private func autoInstallRuntime() async {
        isAutoInstalling = true
        autoInstallError = nil
        autoInstallStatus = "Starte Einrichtung der eigenständigen Laufzeit …"
        autoInstallProgress = 0.05
        defer { isAutoInstalling = false }
        do {
            try await RuntimeInstaller.shared.installAll { prog in
                Task { @MainActor in
                    autoInstallProgress = prog.fractionCompleted
                    autoInstallStatus = prog.statusMessage
                }
            }
            await checkRequirements()
        } catch {
            autoInstallError = error.localizedDescription
            autoInstallStatus = "Fehler: \(error.localizedDescription)"
        }
    }

    private func install() async {
        isInstalling = true
        installError = nil
        installLog = []
        defer { isInstalling = false }
        do {
            if !BridgeEnvironmentManager.shared.isEnvironmentReady() {
                try await BridgeEnvironmentManager.shared.runSetup { line in
                    Task { @MainActor in installLog.append(line) }
                }
            }
            kokoroReady = BridgeEnvironmentManager.shared.isEnvironmentReady()
            if installGerman {
                for voice in ["martin", "victoria"] where !GermanKokoroEnvironmentManager.shared.isVoiceReady(voice) {
                    installLog.append("— \(voice.capitalized) —")
                    try await GermanKokoroEnvironmentManager.shared.install(voice) { line in
                        Task { @MainActor in installLog.append(line) }
                    }
                }
                germanReady = GermanKokoroEnvironmentManager.shared.isVoiceReady("martin")
                if germanReady {
                    settingsStore.settings.defaultVoiceDE = VoiceID(engine: .kokoroGerman, voice: "martin")
                }
            }
            if settingsStore.settings.defaultVoiceEN.engine != .kokoro {
                settingsStore.settings.defaultVoiceEN = VoiceID(engine: .kokoro, voice: "af_heart")
            }
        } catch {
            installError = error.localizedDescription
        }
    }

    private func checkAI() async {
        let status = await DependencyChecker.checkLLMEndpoint(settings: settingsStore.settings)
        switch status.state {
        case .ok(let detail): aiReachable = true; aiStatus = detail
        case .missing(let reason): aiReachable = false; aiStatus = reason
        }
    }
}
