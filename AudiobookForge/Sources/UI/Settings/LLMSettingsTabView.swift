import SwiftUI

struct LLMSettingsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var availableModels: [String] = []
    @State private var modelInfos: [LLMModelInfo] = []
    @State private var serverPreset: LLMServerPreset?

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var settingsStore = settingsStore
        Form {
            Section("Inferenz-Backend") {
                Picker("Backend", selection: $settingsStore.settings.llmProvider) {
                    ForEach(LLMProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("Basis-URL", text: activeBaseURLBinding)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Port", text: portBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button("Standard (\(settingsStore.settings.llmProvider.defaultBaseURL))") {
                        activeBaseURLBinding.wrappedValue = settingsStore.settings.llmProvider.defaultBaseURL
                        testConnection()
                    }
                    Button("Verbinden") { testConnection() }
                }
                SecureField("API-Key (optional)", text: activeAPIKeyBinding)
                    .textFieldStyle(.roundedBorder)
                if !availableModels.isEmpty {
                    Picker("Modell", selection: activeModelBinding) {
                        if !availableModels.contains(settingsStore.settings.activeLLMModel) && !settingsStore.settings.activeLLMModel.isEmpty {
                            Text(settingsStore.settings.activeLLMModel).tag(settingsStore.settings.activeLLMModel)
                        }
                        ForEach(availableModels, id: \.self) { model in Text(model).tag(model) }
                    }
                }
                TextField("Modell-ID", text: activeModelBinding)
                    .textFieldStyle(.roundedBorder)
                Text("Modelle werden über /models geladen. Die ID kann auch manuell eingetragen werden.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Thinking (Reasoning)") {
                Picker("Thinking", selection: generationBinding(\.thinkingMode)) {
                    ForEach(LLMThinkingMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if settingsStore.settings.activeGenerationOptions.thinkingMode != .off {
                    Stepper(value: generationBinding(\.thinkingBudgetTokens), in: 0...65536, step: 1024) {
                        Text("Thinking-Budget: \(settingsStore.settings.activeGenerationOptions.thinkingBudgetTokens == 0 ? "unbegrenzt" : "\(max(settingsStore.settings.activeGenerationOptions.thinkingBudgetTokens, LLMGenerationOptions.minimumThinkingBudget)) Tokens")")
                    }
                    Picker("Reasoning-Tiefe", selection: generationBinding(\.reasoningEffort)) {
                        Text("Nicht senden").tag("")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                    }
                }
                Text(thinkingExplanation)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if let info = selectedModelInfo {
                    LabeledContent("Kontextfenster (Server)", value: info.contextWindow.map { "\($0) Tokens" } ?? "unbekannt")
                }
                ForEach(serverPreset?.warnings ?? [], id: \.self) { warning in
                    Label("oMLX-Preset: \(warning)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                if settingsStore.settings.llmProvider == .omlx {
                    Toggle("Offensichtlich falsche Server-Presets korrigieren (z. B. Top P 95 → 0.95)", isOn: $settingsStore.settings.correctImplausibleServerPresets)
                }
                OptionalDoubleRow(title: "Temperatur", value: generationBinding(\.temperature), serverValue: serverPreset?.temperature, range: 0...2, step: 0.05)
                OptionalDoubleRow(title: "Top P", value: generationBinding(\.topP), serverValue: serverPreset?.topP, range: 0.05...1, step: 0.01)
                OptionalIntRow(title: "Top K", value: generationBinding(\.topK), serverValue: serverPreset?.topK, range: 1...200, step: 1)
                OptionalDoubleRow(title: "Min P", value: generationBinding(\.minP), serverValue: serverPreset?.minP, range: 0...1, step: 0.01)
                OptionalDoubleRow(title: "Presence Penalty", value: generationBinding(\.presencePenalty), serverValue: serverPreset?.presencePenalty, range: 0...2, step: 0.1)
                OptionalDoubleRow(title: "Repetition Penalty", value: generationBinding(\.repetitionPenalty), serverValue: serverPreset?.repetitionPenalty, range: 1...2, step: 0.01)
                OptionalIntRow(title: "Seed", value: generationBinding(\.seed), serverValue: nil, range: 1...999_999, step: 1)
                OptionalIntRow(title: "Max. Ausgabetokens", value: generationBinding(\.maxOutputTokens), serverValue: nil, range: 512...131_072, step: 512, defaultLabel: "Automatisch (aus Eingabelänge)")
                HStack {
                    Button("Modell-Preset als Overrides übernehmen") { adoptServerPreset() }
                        .disabled(serverPreset == nil)
                    Button("Alle auf Modell-Standard") { resetToModelDefaults() }
                }
            } header: {
                Text("Sampling")
            } footer: {
                Text("Nicht überschriebene Werte werden nicht gesendet: Der Server wendet dann sein Preset für das geladene Modell an (oMLX: Modell-Einstellungen). So bleiben Modelle frei austauschbar. Für faktentreue Zusammenfassungen sind Temperatur 0.3–0.5 und Presence Penalty 0 empfehlenswert.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Durchsatz & Grenzen") {
                Stepper("Parallele Anfragen: \(parallelRequestsBinding.wrappedValue)", value: parallelRequestsBinding, in: 1...8)
                Stepper("Kontextlimit: \(settingsStore.settings.llmContextLimitTokens == 0 ? "Automatisch (Server)" : String(settingsStore.settings.llmContextLimitTokens))", value: $settingsStore.settings.llmContextLimitTokens, in: 0...262_144, step: 4096)
                Stepper("Antwort-Timeout: \(Int(settingsStore.settings.llmRequestTimeoutSeconds)) s", value: $settingsStore.settings.llmRequestTimeoutSeconds, in: 30...3600, step: 30)
                Stepper("Verbindungs-Timeout: \(Int(settingsStore.settings.llmConnectionTimeoutSeconds)) s", value: $settingsStore.settings.llmConnectionTimeoutSeconds, in: 1...60, step: 1)
                Text("oMLX verarbeitet parallele Anfragen gemeinsam (Continuous Batching) — 2 beschleunigt Bücher mit vielen Kapiteln deutlich. LM Studio arbeitet Anfragen nacheinander ab. Das Kontextlimit begrenzt die Zeichenmenge pro Aufruf; automatisch wird das vom Server gemeldete Kontextfenster genutzt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settingsStore.settings.llmProvider == .omlx {
                Section("oMLX Server-Verwaltung") {
                    Toggle("oMLX bei Bedarf automatisch starten", isOn: $settingsStore.settings.autoStartOMLX)
                    Text("Startet den oMLX-Hintergrunddienst automatisch über `omlx start`, falls er vor einem Bild- oder Zusammenfassungsdurchlauf nicht erreichbar ist.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("oMLX nach LLM-Phasen automatisch beenden (RAM freigeben)", isOn: $settingsStore.settings.autoUnloadOMLXAfterPass)
                    Text("Beendet den oMLX-Server (`omlx stop`) nach Abschluss der Bild- und Textzusammenfassungen, bevor die Sprachsynthese (TTS) startet. Gibt rund 20+ GB Unified Memory für Kokoro und macOS frei.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Modelle laden / Verbindung testen")
                        }
                    }
                    .disabled(isTesting)

                    if let testResult {
                        switch testResult {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure(let message):
                            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                Text("Wird für Zusammenfassungen und bei aktiviertem Bildpass für Bildbeschreibungen verwendet. Ist der Endpoint nicht erreichbar, bietet die App beim Verarbeiten den Transkriptions-Modus an.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .onAppear { testConnection() }
        .onChange(of: settingsStore.settings.llmProvider) { _, _ in
            availableModels = []
            modelInfos = []
            testConnection()
        }
        .onChange(of: settingsStore.settings.activeLLMModel) { _, _ in refreshPreset() }
    }

    private var selectedModelInfo: LLMModelInfo? {
        modelInfos.first { $0.id == settingsStore.settings.activeLLMModel }
    }

    private var thinkingExplanation: String {
        var text = "Wird über das Chat-Template des Modells gesteuert (enable_thinking) und funktioniert damit für jedes Modell, dessen Template es unterstützt. Für Zusammenfassungen ist „Aus“ meist die beste Wahl: deutlich schneller, kaum Qualitätsverlust beim Verdichten. Ein zu kleines Budget lässt Denktext in die Antwort überlaufen — deshalb mindestens \(LLMGenerationOptions.minimumThinkingBudget) Tokens."
        if settingsStore.settings.llmProvider == .lmStudio {
            text += " LM Studio: Das Abschalten wirkt nur, wenn das Modell-Template es zulässt (beim gespeicherten Qwen3.6-Template ist Thinking fest an); ein Thinking-Budget unterstützt LM Studio nicht."
        }
        return text
    }

    private func generationBinding<T>(_ keyPath: WritableKeyPath<LLMGenerationOptions, T>) -> Binding<T> {
        Binding(
            get: { settingsStore.settings.activeGenerationOptions[keyPath: keyPath] },
            set: { settingsStore.settings.activeGenerationOptions[keyPath: keyPath] = $0 }
        )
    }

    private var parallelRequestsBinding: Binding<Int> {
        Binding(
            get: { settingsStore.settings.llmProvider == .omlx ? settingsStore.settings.omlxParallelRequests : settingsStore.settings.lmStudioParallelRequests },
            set: { if settingsStore.settings.llmProvider == .omlx { settingsStore.settings.omlxParallelRequests = $0 } else { settingsStore.settings.lmStudioParallelRequests = $0 } }
        )
    }

    private func refreshPreset() {
        serverPreset = settingsStore.settings.llmProvider == .omlx
            ? LLMServerPreset.readOMLXPreset(modelID: settingsStore.settings.activeLLMModel)
            : nil
    }

    private func adoptServerPreset() {
        guard let preset = serverPreset else { return }
        var options = settingsStore.settings.activeGenerationOptions
        options.temperature = preset.temperature
        options.topP = preset.topP.map { $0 > 1 ? $0 / 100 : $0 }
        options.topK = preset.topK
        options.minP = preset.minP
        options.presencePenalty = preset.presencePenalty
        options.repetitionPenalty = preset.repetitionPenalty
        settingsStore.settings.activeGenerationOptions = options
    }

    private func resetToModelDefaults() {
        var options = LLMGenerationOptions()
        options.thinkingMode = settingsStore.settings.activeGenerationOptions.thinkingMode
        options.thinkingBudgetTokens = settingsStore.settings.activeGenerationOptions.thinkingBudgetTokens
        options.reasoningEffort = settingsStore.settings.activeGenerationOptions.reasoningEffort
        settingsStore.settings.activeGenerationOptions = options
    }

    private var activeBaseURLBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.activeLLMBaseURL },
            set: { if settingsStore.settings.llmProvider == .omlx { settingsStore.settings.omlxBaseURL = $0 } else { settingsStore.settings.llmBaseURL = $0 } }
        )
    }

    /// Edits just the port of the active base URL (e.g. 1234 → 1235),
    /// keeping scheme, host and path.
    private var portBinding: Binding<String> {
        Binding(
            get: { URLComponents(string: settingsStore.settings.activeLLMBaseURL)?.port.map(String.init) ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                guard var components = URLComponents(string: settingsStore.settings.activeLLMBaseURL) else { return }
                components.port = Int(digits).flatMap { (1...65535).contains($0) ? $0 : nil }
                if let url = components.string { activeBaseURLBinding.wrappedValue = url }
            }
        )
    }

    private var activeAPIKeyBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.activeLLMAPIKey },
            set: { if settingsStore.settings.llmProvider == .omlx { settingsStore.settings.omlxAPIKey = $0 } else { settingsStore.settings.llmAPIKey = $0 } }
        )
    }

    private var activeModelBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.activeLLMModel },
            set: { if settingsStore.settings.llmProvider == .omlx { settingsStore.settings.omlxModel = $0 } else { settingsStore.settings.llmModel = $0 } }
        )
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let requestedSettings = settingsStore.settings
        let client = LLMClient(settings: requestedSettings)
        Task {
            let result: Result<[LLMModelInfo], Error>
            do { result = .success(try await client.listModels()) } catch { result = .failure(error) }
            await MainActor.run {
                guard requestedSettings.llmProvider == settingsStore.settings.llmProvider else { return }
                isTesting = false
                switch result {
                case .success(let models):
                    modelInfos = models
                    availableModels = models.map(\.id).sorted()
                    if settingsStore.settings.activeLLMModel.isEmpty,
                       let preferred = LLMClient.preferredModel(from: models.map(\.id), hint: settingsStore.settings.llmModel) {
                        settingsStore.settings.activeLLMModel = preferred
                    }
                    if !settingsStore.settings.activeLLMModel.isEmpty && !availableModels.contains(settingsStore.settings.activeLLMModel) {
                        testResult = .failure("Erreichbar, aber Modell „\(settingsStore.settings.activeLLMModel)“ ist dort nicht verfügbar")
                    } else {
                        testResult = .success("Erreichbar (\(models.count) Modell(e))")
                    }
                case .failure(let error):
                    testResult = .failure(error.localizedDescription)
                }
                refreshPreset()
            }
        }
    }
}

/// One optional sampling parameter: off = "Modell-Standard" (not sent,
/// shows the server preset value if known), on = explicit override.
private struct OptionalDoubleRow: View {
    let title: String
    @Binding var value: Double?
    let serverValue: Double?
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? min(max(serverValue ?? range.lowerBound, range.lowerBound), range.upperBound) : nil }
            )) {
                HStack {
                    Text(title)
                    Spacer()
                    if let value {
                        Text(String(format: "%.2f", value)).monospacedDigit()
                    } else {
                        Text("Modell-Standard\(serverValue.map { String(format: " (%.2f)", $0) } ?? "")")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let current = value {
                Slider(value: Binding(get: { current }, set: { value = ($0 / step).rounded() * step }), in: range)
            }
        }
    }
}

private struct OptionalIntRow: View {
    let title: String
    @Binding var value: Int?
    let serverValue: Int?
    let range: ClosedRange<Int>
    let step: Int
    var defaultLabel: String = "Modell-Standard"

    var body: some View {
        Toggle(isOn: Binding(
            get: { value != nil },
            set: { value = $0 ? min(max(serverValue ?? range.lowerBound, range.lowerBound), range.upperBound) : nil }
        )) {
            HStack {
                Text(title)
                Spacer()
                if let current = value {
                    Stepper(value: Binding(get: { current }, set: { value = $0 }), in: range, step: step) {
                        Text("\(current)").monospacedDigit()
                    }
                    .fixedSize()
                } else {
                    Text("\(defaultLabel)\(serverValue.map { " (\($0))" } ?? "")")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
