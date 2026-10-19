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
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Sprachmodell", footer: "Für Zusammenfassungen und Bildbeschreibungen. Ist der Server nicht erreichbar, bietet die App den Transkriptions-Modus an.") {
                PillRow(title: "Backend") {
                    SegmentedPills(selection: $store.settings.llmProvider,
                                   options: LLMProviderID.allCases.map { PillOption(value: $0, label: $0.displayName) })
                }
                PillRow(title: "Server", subtitle: String(localized: "Basis-URL — Standard: \(settingsStore.settings.llmProvider.defaultBaseURL)")) {
                    HStack(spacing: 8) {
                        TextField("http://localhost:8000/v1", text: activeBaseURLBinding)
                            .textFieldStyle(.flow)
                            .frame(width: 240)
                        Button("Standard") {
                            activeBaseURLBinding.wrappedValue = settingsStore.settings.llmProvider.defaultBaseURL
                            testConnection()
                        }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                    }
                }
                PillRow(title: "API-Key", subtitle: "Optional") {
                    SecureField("—", text: activeAPIKeyBinding)
                        .textFieldStyle(.flow)
                        .frame(width: 240)
                }
                PillRow(title: "Modell", subtitle: selectedModelInfo?.contextWindow.map { "Kontextfenster: \($0) Tokens" } ?? "Über „Verbinden“ geladen oder manuell eingetragen") {
                    HStack(spacing: 8) {
                        if !availableModels.isEmpty {
                            PillPicker(selection: activeModelBinding, options: modelOptions, minWidth: 200)
                        } else {
                            TextField("Modell-ID", text: activeModelBinding)
                                .textFieldStyle(.flow)
                                .frame(width: 240)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        testConnection()
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Verbinden & Modelle laden", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .buttonStyle(.flowProminent)
                    .disabled(isTesting)
                    if let testResult {
                        switch testResult {
                        case .success(let message):
                            StatusBadge(text: message, systemImage: "checkmark.circle.fill", tint: .green)
                        case .failure(let message):
                            StatusBadge(text: message, systemImage: "xmark.circle.fill", tint: .red)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }

            PillSection("Thinking", footer: thinkingExplanation) {
                PillRow(title: "Thinking (Reasoning)") {
                    SegmentedPills(selection: generationBinding(\.thinkingMode),
                                   options: LLMThinkingMode.allCases.map { PillOption(value: $0, label: $0.displayName) }, size: .small)
                }
                if settingsStore.settings.activeGenerationOptions.thinkingMode != .off {
                    PillRow(title: "Thinking-Budget", subtitle: "0 = unbegrenzt") {
                        PillStepper(value: generationBinding(\.thinkingBudgetTokens), range: 0...65536, step: 1024, suffix: "Tokens")
                    }
                    PillRow(title: "Reasoning-Tiefe") {
                        SegmentedPills(selection: generationBinding(\.reasoningEffort), options: [
                            PillOption(value: "", label: "Nicht senden"),
                            PillOption(value: "low", label: "low"),
                            PillOption(value: "medium", label: "medium"),
                            PillOption(value: "high", label: "high"),
                        ], size: .small)
                    }
                }
            }

            PillSection("Sampling", footer: "Nicht überschriebene Werte werden nicht gesendet — der Server nutzt sein Modell-Preset. Für faktentreue Zusammenfassungen: Temperatur 0.3–0.5, Presence Penalty 0.") {
                ForEach(serverPreset?.warnings ?? [], id: \.self) { warning in
                    Label(String(localized: "oMLX-Preset: \(warning)"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).flowFont(.caption)
                        .padding(.horizontal, 6)
                }
                if settingsStore.settings.llmProvider == .omlx {
                    PillRow(title: "Offensichtlich falsche Server-Presets korrigieren (z. B. Top P 95 → 0.95)") {
                        PillToggle(isOn: $store.settings.correctImplausibleServerPresets)
                    }
                }
                OptionalDoubleRow(title: "Temperatur", value: generationBinding(\.temperature), serverValue: serverPreset?.temperature, range: 0...2, step: 0.05)
                OptionalDoubleRow(title: "Top P", value: generationBinding(\.topP), serverValue: serverPreset?.topP, range: 0.05...1, step: 0.01)
                OptionalIntRow(title: "Top K", value: generationBinding(\.topK), serverValue: serverPreset?.topK, range: 1...200, step: 1)
                OptionalDoubleRow(title: "Min P", value: generationBinding(\.minP), serverValue: serverPreset?.minP, range: 0...1, step: 0.01)
                OptionalDoubleRow(title: "Presence Penalty", value: generationBinding(\.presencePenalty), serverValue: serverPreset?.presencePenalty, range: 0...2, step: 0.1)
                OptionalDoubleRow(title: "Repetition Penalty", value: generationBinding(\.repetitionPenalty), serverValue: serverPreset?.repetitionPenalty, range: 1...2, step: 0.01)
                OptionalIntRow(title: "Seed", value: generationBinding(\.seed), serverValue: nil, range: 1...999_999, step: 1)
                OptionalIntRow(title: "Max. Ausgabetokens", value: generationBinding(\.maxOutputTokens), serverValue: nil, range: 512...131_072, step: 512, defaultLabel: "Automatisch")
                HStack {
                    Button("Preset als Overrides übernehmen") { adoptServerPreset() }
                        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                        .disabled(serverPreset == nil)
                    Button("Alle auf Modell-Standard") { resetToModelDefaults() }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                }
                .padding(.top, 4)
            }

            PillSection("Durchsatz & Grenzen", footer: "oMLX verarbeitet parallele Anfragen gemeinsam (Continuous Batching); LM Studio nacheinander. Kontextlimit 0 = vom Server gemeldetes Fenster.") {
                PillRow(title: "Parallele Anfragen") {
                    PillStepper(value: parallelRequestsBinding, range: 1...8)
                }
                PillRow(title: "Kontextlimit", subtitle: "0 = automatisch") {
                    PillStepper(value: $store.settings.llmContextLimitTokens, range: 0...262_144, step: 4096, suffix: "Tokens")
                }
                PillRow(title: "Antwort-Timeout") {
                    PillSlider(value: $store.settings.llmRequestTimeoutSeconds, range: 30...3600, step: 30, format: "%.0f s")
                }
                PillRow(title: "Verbindungs-Timeout") {
                    PillSlider(value: $store.settings.llmConnectionTimeoutSeconds, range: 1...60, step: 1, format: "%.0f s")
                }
            }

            if settingsStore.settings.llmProvider == .omlx {
                PillSection("oMLX-Server") {
                    PillRow(title: "Bei Bedarf automatisch starten", subtitle: "`omlx start`, falls der Server vor einem KI-Durchlauf nicht läuft.") {
                        PillToggle(isOn: $store.settings.autoStartOMLX)
                    }
                    PillRow(title: "Nach KI-Phasen beenden", subtitle: "Gibt vor dem Einsprechen ~20 GB Speicher frei (`omlx stop`).") {
                        PillToggle(isOn: $store.settings.autoUnloadOMLXAfterPass)
                    }
                }
            }
        }
        .onChange(of: settingsStore.settings.llmProvider) { _, _ in
            availableModels = []
            modelInfos = []
            testConnection()
        }
        .onChange(of: settingsStore.settings.activeLLMModel) { _, _ in refreshPreset() }
    }

    private var modelOptions: [PillOption<String>] {
        var ids = availableModels
        let current = settingsStore.settings.activeLLMModel
        if !current.isEmpty && !ids.contains(current) { ids.insert(current, at: 0) }
        return ids.map { PillOption(value: $0, label: $0) }
    }

    private var selectedModelInfo: LLMModelInfo? {
        modelInfos.first { $0.id == settingsStore.settings.activeLLMModel }
    }

    private var thinkingExplanation: String {
        var text = String(localized: "Wird über das Chat-Template des Modells gesteuert (enable_thinking) und funktioniert damit für jedes Modell, dessen Template es unterstützt. Für Zusammenfassungen ist „Aus“ meist die beste Wahl: deutlich schneller, kaum Qualitätsverlust beim Verdichten. Ein zu kleines Budget lässt Denktext in die Antwort überlaufen — deshalb mindestens \(LLMGenerationOptions.minimumThinkingBudget) Tokens.")
        if settingsStore.settings.llmProvider == .lmStudio {
            text += L(" LM Studio: Das Abschalten wirkt nur, wenn das Modell-Template es zulässt (beim gespeicherten Qwen3.6-Template ist Thinking fest an); ein Thinking-Budget unterstützt LM Studio nicht.")
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

    /// Off = not sent, the server's model preset applies.
    private var isOverridden: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? min(max(serverValue ?? range.lowerBound, range.lowerBound), range.upperBound) : nil }
        )
    }

    var body: some View {
        PillRow(title: title, subtitle: value == nil ? L("Modell-Standard") + (serverValue.map { String(format: " (%.2f)", $0) } ?? "") : nil) {
            HStack(spacing: 14) {
                if let current = value {
                    PillSlider(value: Binding(get: { current }, set: { value = ($0 / step).rounded() * step }), range: range, step: step)
                }
                PillToggle(isOn: isOverridden)
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

    private var isOverridden: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? min(max(serverValue ?? range.lowerBound, range.lowerBound), range.upperBound) : nil }
        )
    }

    var body: some View {
        PillRow(title: title, subtitle: value == nil ? L(defaultLabel) + (serverValue.map { " (\($0))" } ?? "") : nil) {
            HStack(spacing: 14) {
                if let current = value {
                    PillStepper(value: Binding(get: { current }, set: { value = $0 }), range: range, step: step)
                }
                PillToggle(isOn: isOverridden)
            }
        }
    }
}
