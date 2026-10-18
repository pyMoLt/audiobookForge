import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TTSSettingsTabView()
                .tabItem { Label("TTS-Engine", systemImage: "waveform") }
            LLMSettingsTabView()
                .tabItem { Label("LLM-Endpoint", systemImage: "brain") }
            ImageSettingsTabView()
                .tabItem { Label("Bilder & Lehrbücher", systemImage: "photo.on.rectangle") }
            OutputSettingsTabView()
                .tabItem { Label("Ausgabe & Ordner", systemImage: "folder") }
            PromptsSettingsTabView()
                .tabItem { Label("Prompt-Vorlagen", systemImage: "text.bubble") }
            DiagnosticsTabView()
                .tabItem { Label("Diagnose", systemImage: "stethoscope") }
        }
        .padding(24)
        .navigationTitle("Einstellungen")
    }
}

struct TTSSettingsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var settingsStore = settingsStore
        Form {
            Section("Standard-Engine für neue Importe") {
                Picker("TTS-Engine", selection: $settingsStore.settings.ttsEngine) {
                    ForEach(TTSEngineID.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Toggle("Engine automatisch nach erkannter Sprache wählen (Deutsch → gewählte deutsche Engine oder Piper)", isOn: $settingsStore.settings.autoSelectEngineByLanguage)
                Text("Die Engine und Stimme sind pro Buch in der Review-Ansicht änderbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Performance & Parallelisierung") {
                Stepper("Parallele Audio-Worker: \(settingsStore.settings.ttsParallelWorkers)", value: $settingsStore.settings.ttsParallelWorkers, in: 1...4)
                Text("Bestimmt, wie viele Kapitel gleichzeitig synthetisiert werden (1–4). Auf Apple Silicon bieten 2 parallele Worker die höchste Durchsatzsteigerung (+40–50 %) bei flüssiger Systemreaktionszeit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Kokoro-Parameter") {
                Picker("Standardstimme", selection: $settingsStore.settings.kokoroVoice) {
                    ForEach(KokoroEngine.standardVoices) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
                HStack {
                    Text("Geschwindigkeit")
                    Slider(value: $settingsStore.settings.kokoroSpeed, in: 0.5...2.0, step: 0.05)
                    Text("\(settingsStore.settings.kokoroSpeed, specifier: "%.2f")×")
                        .monospacedDigit()
                        .frame(width: 50)
                }
                TextField("Modell-Repo (mlx-audio / Hugging Face)", text: $settingsStore.settings.kokoroModelRepo)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Piper-Parameter") {
                Picker("Standardstimme", selection: $settingsStore.settings.piperVoice) {
                    ForEach(PiperVoiceCatalog.allVoices) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
                HStack {
                    Text("Geschwindigkeit")
                    Slider(value: $settingsStore.settings.piperSpeed, in: 0.5...2.0, step: 0.05)
                    Text("\(settingsStore.settings.piperSpeed, specifier: "%.2f")×")
                        .monospacedDigit()
                        .frame(width: 50)
                }
            }

            Section("Piper-Stimmen verwalten") {
                PiperVoiceManagerView()
            }

            Section("Stimmvorschau") {
                Stepper("Sätze: \(settingsStore.settings.voicePreviewSentenceCount)", value: $settingsStore.settings.voicePreviewSentenceCount, in: 1...8)
                Stepper("Maximale Zeichen: \(settingsStore.settings.voicePreviewMaxCharacters)", value: $settingsStore.settings.voicePreviewMaxCharacters, in: 40...1200, step: 20)
            }

            Section("Kokoro Deutsch (MLX)") {
                Picker("Standardstimme", selection: $settingsStore.settings.kokoroGermanVoice) {
                    Text("Martin (männlich)").tag("martin")
                    Text("Victoria (weiblich)").tag("victoria")
                }
                HStack {
                    Text("Geschwindigkeit")
                    Slider(value: $settingsStore.settings.kokoroGermanSpeed, in: 0.5...2.0, step: 0.05)
                    Text("\(settingsStore.settings.kokoroGermanSpeed, specifier: "%.2f")×")
                }
                GermanKokoroModelManagerView(voices: ["martin", "victoria"])
            }

            Section("Kokoro Thorsten (MLX)") {
                HStack {
                    Text("Geschwindigkeit")
                    Slider(value: $settingsStore.settings.kokoroThorstenSpeed, in: 0.5...2.0, step: 0.05)
                    Text("\(settingsStore.settings.kokoroThorstenSpeed, specifier: "%.2f")×")
                }
                GermanKokoroModelManagerView(voices: ["thorsten"])
            }

            Section("Supertonic 3 (MLX)") {
                Picker("Standardstimme", selection: $settingsStore.settings.supertonicVoice) {
                    ForEach(SupertonicEngine(settings: settingsStore.settings, environment: .shared).availableVoices()) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
                HStack {
                    Text("Geschwindigkeit")
                    Slider(value: $settingsStore.settings.supertonicSpeed, in: 0.7...2.0, step: 0.05)
                    Text("\(settingsStore.settings.supertonicSpeed, specifier: "%.2f")×")
                }
                Stepper("Syntheseschritte: \(settingsStore.settings.supertonicSteps)", value: $settingsStore.settings.supertonicSteps, in: 1...20)
                Stepper("Zeichen pro Segment: \(settingsStore.settings.supertonicChunkCharacters)", value: $settingsStore.settings.supertonicChunkCharacters, in: 40...300, step: 10)
                HStack {
                    Text("Pause zwischen Segmenten")
                    Slider(value: $settingsStore.settings.supertonicPauseSeconds, in: 0...1, step: 0.05)
                    Text("\(settingsStore.settings.supertonicPauseSeconds, specifier: "%.2f") s")
                }
                SupertonicModelManagerView()
            }
        }
        .formStyle(.grouped)
    }
}

private struct GermanKokoroModelManagerView: View {
    let voices: [String]
    private let manager = GermanKokoroEnvironmentManager.shared
    @State private var installing: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(voices, id: \.self) { voice in
                HStack {
                    Text(voice.capitalized)
                    Spacer()
                    if manager.isVoiceReady(voice) {
                        Label("Bereit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(installing == voice ? "Installiere …" : "Modell installieren") {
                            install(voice)
                        }
                        .disabled(installing != nil)
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func install(_ voice: String) {
        installing = voice
        message = "Lade und konvertiere \(voice)…"
        Task {
            do {
                try await manager.install(voice) { line in
                    Task { @MainActor in message = line }
                }
                installing = nil
                message = "\(voice.capitalized) ist bereit."
            } catch {
                installing = nil
                message = error.localizedDescription
            }
        }
    }
}

private struct SupertonicModelManagerView: View {
    private let manager = SupertonicEnvironmentManager.shared
    @State private var installing = false
    @State private var message: String?

    var body: some View {
        HStack {
            if manager.isReady() {
                Label("Supertonic 3 MLX bereit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(installing ? "Installiere …" : "Modell und MLX-Laufzeit installieren") { install() }
                    .disabled(installing)
            }
            Spacer()
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    private func install() {
        installing = true
        message = "Lade Supertonic 3…"
        Task {
            do {
                try await manager.install { line in Task { @MainActor in message = line } }
                installing = false
                message = "Supertonic 3 MLX ist bereit."
            } catch {
                installing = false
                message = error.localizedDescription
            }
        }
    }
}

private struct PiperVoiceManagerView: View {
    private let environment = PiperEnvironmentManager.shared
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadedFlags: [String: Bool] = [:]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PiperVoiceCatalog.allVoices) { voice in
                HStack {
                    Text(voice.displayName)
                    Spacer()
                    if let progress = downloadProgress[voice.id] {
                        ProgressView(value: progress).frame(width: 100)
                    } else if isDownloaded(voice) {
                        Label("Heruntergeladen", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Herunterladen (~60 MB)") { download(voice) }
                            .disabled(!environment.isEnvironmentReady())
                    }
                }
            }
            if !environment.isEnvironmentReady() {
                Text("Piper-Umgebung muss zuerst unter „Diagnose“ eingerichtet werden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { refresh() }
    }

    private func isDownloaded(_ voice: PiperVoice) -> Bool {
        downloadedFlags[voice.id] ?? environment.isVoiceDownloaded(voice.id)
    }

    private func refresh() {
        for voice in PiperVoiceCatalog.allVoices {
            downloadedFlags[voice.id] = environment.isVoiceDownloaded(voice.id)
        }
    }

    private func download(_ voice: PiperVoice) {
        downloadProgress[voice.id] = 0.01
        Task {
            do {
                try await environment.downloadVoice(voice) { progress in
                    Task { @MainActor in downloadProgress[voice.id] = progress }
                }
                await MainActor.run {
                    downloadProgress[voice.id] = nil
                    downloadedFlags[voice.id] = true
                }
            } catch {
                await MainActor.run {
                    downloadProgress[voice.id] = nil
                    errorMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct OutputSettingsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var showFolderPicker = false

    var body: some View {
        @Bindable var settingsStore = settingsStore
        Form {
            Section("Standard-Ausgabeformat") {
                Picker("Format", selection: $settingsStore.settings.defaultOutputFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
            }

            Section("Audioqualität") {
                Stepper("MP3-Qualität (0 = höchste): \(settingsStore.settings.mp3Quality)", value: $settingsStore.settings.mp3Quality, in: 0...9)
                Stepper("AAC-Bitrate: \(settingsStore.settings.aacBitrateKbps) kbit/s", value: $settingsStore.settings.aacBitrateKbps, in: 64...320, step: 16)
                Toggle("Lautheit normalisieren", isOn: $settingsStore.settings.loudnessNormalizationEnabled)
                if settingsStore.settings.loudnessNormalizationEnabled {
                    Stepper("Ziel-Lautheit: \(settingsStore.settings.loudnessTargetLUFS, specifier: "%.1f") LUFS", value: $settingsStore.settings.loudnessTargetLUFS, in: -30 ... -10, step: 0.5)
                    Stepper("True Peak: \(settingsStore.settings.loudnessTruePeakDB, specifier: "%.1f") dB", value: $settingsStore.settings.loudnessTruePeakDB, in: -6 ... -0.5, step: 0.5)
                    Stepper("Loudness Range: \(settingsStore.settings.loudnessRangeLU, specifier: "%.1f") LU", value: $settingsStore.settings.loudnessRangeLU, in: 1...20, step: 1)
                }
            }

            Section("Zielordner") {
                HStack {
                    TextField("Basisordner", text: $settingsStore.settings.outputBaseFolderPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Wählen…") { showFolderPicker = true }
                }
                Picker("Unterordner-Struktur", selection: $settingsStore.settings.outputFolderTemplate) {
                    ForEach(OutputFolderTemplate.allCases) { template in
                        Text(template.displayName).tag(template)
                    }
                }
            }

            Section("Dokumenttyp") {
                Picker("Standard für neue Importe", selection: $settingsStore.settings.defaultDocumentType) {
                    ForEach(DocumentType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                Text(settingsStore.settings.defaultDocumentType.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Wirkt beim Import auf die Mindestkapitelgröße unten; nach dem Import ist der Typ pro Buch im Review-Bildschirm änderbar (wirkt dort noch auf das Zusammenfassungs-Budget).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dokumenttyp-Feinabstimmung") {
                Text("„Allgemein“ nutzt die manuellen Regler unter „Text-Bereinigung“ direkt. Buch/Paper/Report haben eigene Werte, hier änderbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                documentTypeTuningRow(title: "Buch", tuning: $settingsStore.settings.bookTuning)
                Divider()
                documentTypeTuningRow(title: "Paper", tuning: $settingsStore.settings.paperTuning)
                Divider()
                documentTypeTuningRow(title: "Report", tuning: $settingsStore.settings.reportTuning)
            }

            Section("Text-Bereinigung") {
                Toggle("Wiederkehrende Kopf-/Fußzeilen entfernen", isOn: $settingsStore.settings.stripRecurringHeadersFooters)
                Toggle("Fußnoten/Referenzen einbeziehen", isOn: $settingsStore.settings.includeFootnotes)
                Toggle("Literaturverzeichnis/Danksagungen ausschließen", isOn: $settingsStore.settings.excludeBackMatterSections)
                Stepper(value: $settingsStore.settings.minimumChapterCharacters, in: 0...5000, step: 100) {
                    Text("Mindestgröße pro Kapitel: \(settingsStore.settings.minimumChapterCharacters) Zeichen")
                }
                Text("Kürzere Kapitel (z. B. eine vereinzelte Unterüberschrift) werden mit dem vorherigen Kapitel zusammengeführt, statt als eigener, wenige-Sekunden-Abschnitt zu erscheinen. 0 = deaktiviert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Automatische Kapitelteilung") {
                Toggle("Ohne Inhaltsverzeichnis/Überschriften automatisch teilen", isOn: $settingsStore.settings.autoSplitEnabled)
                if settingsStore.settings.autoSplitEnabled {
                    Stepper(value: $settingsStore.settings.autoSplitTargetCharacters, in: 3000...60000, step: 1000) {
                        Text("Zielgröße: ~\(settingsStore.settings.autoSplitTargetCharacters / 1000)k Zeichen (≈ \(settingsStore.settings.autoSplitTargetCharacters / 900) min)")
                    }
                }
                Text("Findet der Import weder Inhaltsverzeichnis noch erkennbare Überschriften, wird der Text an Absatzgrenzen in etwa gleich große Kapitel geteilt, damit das Hörbuch navigierbar bleibt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                settingsStore.settings.outputBaseFolderPath = url.path
            }
        }
    }

    @ViewBuilder
    private func documentTypeTuningRow(title: String, tuning: Binding<DocumentTypeTuning>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Stepper(value: tuning.minimumChapterCharacters, in: 0...5000, step: 50) {
                Text("Mindestgröße pro Kapitel: \(tuning.wrappedValue.minimumChapterCharacters) Zeichen")
            }
            Stepper(value: tuning.summarizationChunkCharacterBudget, in: 10000...150000, step: 5000) {
                Text("Zusammenfassungs-Budget: ~\(tuning.wrappedValue.summarizationChunkCharacterBudget / 1000)k Zeichen pro Aufruf")
            }
        }
        .padding(.vertical, 2)
    }
}
