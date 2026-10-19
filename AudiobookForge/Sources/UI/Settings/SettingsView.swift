import SwiftUI

/// Settings (v3.1): one page per area, chosen in the main sidebar
/// (`SettingsPane`). Every page is built from the same pill rows; switching
/// pages turns the page like a book. Nothing appears twice — the v3.0
/// screens showed the document type in three places and "Galerie öffnen"
/// four times.
struct SettingsView: View {
    var pane: SettingsPane = .voices

    init(pane: SettingsPane = .voices) {
        self.pane = pane
    }

    /// Every settings field appears in exactly one area (plan 9.3 —
    /// nothing is lost; the mirror test walks this mapping).
    static let settingsBuckets: [(name: String, fields: [String])] = [
        ("Stimmen", ["defaultVoiceDE", "defaultVoiceEN", "preferredCloneEngine", "voicePreviewSentenceCount", "voicePreviewMaxCharacters", "autoSelectEngineByLanguage"]),
        ("Sprechfluss", ["sentencePauseMs", "paragraphPauseMs", "headingPauseMs", "listItemPauseMs", "figurePauseMs", "chapterLeadInMs", "chapterTailMs", "pauseJitterPercent", "kokoroSpeed", "kokoroGermanSpeed", "kokoroThorstenSpeed", "piperSpeed", "piperNoiseScale", "piperNoiseW", "supertonicSpeed", "supertonicPauseSeconds"]),
        ("Ausgabe", ["defaultOutputFormat", "outputBaseFolderPath", "outputFolderTemplate", "mp3Quality", "aacBitrateKbps", "chapterAudioBitrateKbps", "loudnessNormalizationEnabled", "loudnessTargetLUFS", "loudnessTruePeakDB", "loudnessRangeLU", "keepChapterAudioAfterPackaging"]),
        ("Textaufbereitung", ["stripRecurringHeadersFooters", "includeFootnotes", "minimumChapterCharacters", "targetChapterCharacters", "excludeBackMatterSections", "defaultDocumentType", "bookTuning", "paperTuning", "reportTuning", "autoSplitEnabled", "autoSplitTargetCharacters", "boxLabelHandling", "speakHeadingNumbers"]),
        ("KI & Zusammenfassung", ["llmProvider", "llmBaseURL", "llmAPIKey", "llmModel", "omlxBaseURL", "omlxAPIKey", "omlxModel", "omlxGeneration", "lmStudioGeneration", "omlxParallelRequests", "lmStudioParallelRequests", "llmContextLimitTokens", "llmRequestTimeoutSeconds", "llmConnectionTimeoutSeconds", "correctImplausibleServerPresets", "autoStartOMLX", "autoUnloadOMLXAfterPass", "promptTemplates", "summarizationChunkCharacterBudget", "aiChapterMaxCharacters", "minAIChapterCharacters", "aiChapterContinuityEnabled", "summarizationBatchTolerance"]),
        ("Bilder", ["llmVisionTimeoutSeconds", "llmVisionThinkingMode", "llmVisionModelOverride", "describeImagesWithVisionModel", "minimumImageDimensionForVisionPass", "imageDescriptionScope", "minimumImageAreaPercent", "minimumImageKilobytes", "maximumImageAspectRatio", "detectVectorFigures", "removeFigureLabelText", "keepFigureCaptions", "removeCrossReferences", "visionParallelRequests", "imageDescriptionLabel"]),
        ("Erscheinungsbild", ["appearanceMode", "textSizeStep", "accent", "glassIntensity", "motionMode", "flowBackgroundEnabled", "sidebarGrouping", "appLanguage"]),
        ("Engines & Leistung", ["ttsEngine", "ttsParallelWorkers", "powerModeOnAdapter", "powerModeOnBattery", "kokoroVoice", "kokoroModelRepo", "piperVoice", "kokoroGermanVoice", "supertonicVoice", "supertonicSteps", "supertonicChunkCharacters", "omniVoiceSteps", "ramWatchdog", "ramWatchdogEnabled", "ramWatchdogAuto", "ramWatchdogManualLimitGB", "speicher"]),
        ("Diagnose", ["dependencyPathOverrides"]),
    ]

    /// Page lying underneath (the destination when turning forward).
    @State private var basePane: SettingsPane?
    /// Page currently swinging around the spine, on top of everything.
    @State private var turningPane: SettingsPane?
    @State private var turnAngle: Double = 0

    var body: some View {
        let base = basePane ?? pane
        ZStack {
            page(base)
                .overlay {
                    // The page underneath sits in the turning page's shadow.
                    Color.black.opacity(turningPane == nil ? 0 : 0.16 * (1 - abs(turnAngle) / 90))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                        .allowsHitTesting(false)
                }
                .zIndex(0)
            if let turningPane {
                page(turningPane)
                    .overlay {
                        // Light catching the lifted page.
                        LinearGradient(colors: [.clear, Color.white.opacity(0.35 * abs(turnAngle) / 90)], startPoint: .leading, endPoint: .trailing)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                            .allowsHitTesting(false)
                    }
                    .rotation3DEffect(.degrees(turnAngle), axis: (x: 0, y: 1, z: 0), anchor: .leading, anchorZ: 0, perspective: 0.35)
                    .shadow(color: .black.opacity(0.28 * abs(turnAngle) / 90 + 0.05), radius: 26, x: 18)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 4)
        .navigationTitle(pane.title)
        .onChange(of: pane) { old, new in turn(from: old, to: new) }
    }

    private func page(_ pane: SettingsPane) -> some View {
        SettingsPage(pane: pane)
            .background { PaperPage() }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    /// Forward: the current page lies on top and swings away over the
    /// spine, revealing the next one. Backward: the previous page swings
    /// back from the spine and settles on top.
    private func turn(from old: SettingsPane, to new: SettingsPane) {
        let order = SettingsPane.allCases
        let forward = (order.firstIndex(of: new) ?? 0) >= (order.firstIndex(of: old) ?? 0)
        let duration = 0.6
        if forward {
            basePane = new
            turningPane = old
            turnAngle = 0
            withAnimation(.timingCurve(0.5, 0.0, 0.3, 1, duration: duration)) {
                turnAngle = -90
            } completion: {
                turningPane = nil
                turnAngle = 0
            }
        } else {
            basePane = old
            turningPane = new
            turnAngle = -90
            withAnimation(.timingCurve(0.3, 0.0, 0.25, 1, duration: duration)) {
                turnAngle = 0
            } completion: {
                basePane = new
                turningPane = nil
            }
        }
    }
}

/// An opaque sheet of paper: the settings page, the read-along page.
struct PaperPage: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(colorScheme == .dark ? Color(red: 0.115, green: 0.11, blue: 0.105) : Color(red: 0.99, green: 0.982, blue: 0.965))
            // Spine shadow along the bound edge.
            LinearGradient(colors: [Color.black.opacity(colorScheme == .dark ? 0.4 : 0.09), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 30)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.7), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.1), radius: 18, y: 8)
    }
}

/// One settings page: book-style chapter heading + the area's rows.
private struct SettingsPage: View {
    let pane: SettingsPane

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                BookPageHeading(
                    overline: pane.group.rawValue,
                    title: pane.title,
                    subtitle: pane.subtitle,
                    systemImage: pane.systemImage
                )
                content
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .voices: VoicesSettingsPane()
        case .speech: SpeechSettingsPane()
        case .output: OutputSettingsPane()
        case .text: TextSettingsPane()
        case .ai: AISettingsPane()
        case .images: ImageSettingsTabView()
        case .appearance: AppearanceSettingsSection()
        case .engines: EnginesSettingsPane()
        case .diagnostics: DiagnosticsTabView()
        }
    }
}

/// Chapter-style heading used by settings pages: icon tile, small-caps
/// overline, serif title.
struct BookPageHeading: View {
    let overline: String
    let title: String
    var subtitle: String? = nil
    var systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            AppIconTile(systemImage: systemImage, size: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(overline))
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Text(L(title))
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                if let subtitle {
                    Text(L(subtitle))
                        .flowFont(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Page-turn transition

/// Settings pages turn like the pages of a book, fully opaque.
/// Forward: the current page lifts at its right edge and swings over the
/// spine (left edge) while the next page lies underneath. Backward: the
/// previous page swings back from the spine onto the stack.
struct PageTurnTransition: Transition {
    var forward: Bool = true

    func body(content: Content, phase: TransitionPhase) -> some View {
        // The moving page is the leaving one when turning forward and the
        // arriving one when turning back.
        let isMoving = forward ? phase == .didDisappear : phase == .willAppear
        let isUnder = !isMoving && phase != .identity
        content
            .overlay {
                // Shade: the page underneath is in the turning page's shadow.
                Rectangle().fill(Color.black.opacity(isUnder ? 0.18 : 0)).allowsHitTesting(false)
            }
            .overlay {
                // Light catching the curling page.
                LinearGradient(colors: [.clear, Color.white.opacity(isMoving ? 0.25 : 0)], startPoint: .leading, endPoint: .trailing)
                    .allowsHitTesting(false)
            }
            .rotation3DEffect(.degrees(isMoving ? -88 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, anchorZ: 0, perspective: 0.35)
            .shadow(color: .black.opacity(isMoving ? 0.3 : 0), radius: 30, x: 20)
            .zIndex(isMoving ? 2 : 1)
    }
}

extension AnyTransition {
    static var pageTurn: AnyTransition { AnyTransition(PageTurnTransition()) }
    static func pageTurn(forward: Bool) -> AnyTransition { AnyTransition(PageTurnTransition(forward: forward)) }
}

// MARK: - Voices

private struct VoicesSettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var galleryMode: GalleryRequest?

    struct GalleryRequest: Identifiable {
        let id = UUID()
        let languageCode: String?
    }

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Standardstimmen", footer: "Neue Bücher bekommen automatisch die Stimme ihrer Sprache — pro Buch in der Prüfung änderbar.") {
                DefaultVoiceCard(language: "Deutsch", flag: "DE", voice: $store.settings.defaultVoiceDE, languageCode: "de") {
                    galleryMode = GalleryRequest(languageCode: "de")
                }
                DefaultVoiceCard(language: "Englisch", flag: "EN", voice: $store.settings.defaultVoiceEN, languageCode: "en") {
                    galleryMode = GalleryRequest(languageCode: "en")
                }
                PillRow(title: "Engine nach Sprache wählen", subtitle: "Erkennt die Buchsprache und nimmt die passende Standardstimme.") {
                    PillToggle(isOn: $store.settings.autoSelectEngineByLanguage)
                }
            }

            PillSection("Stimmen-Galerie") {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Alle Stimmen durchhören").flowFont(.body, weight: .semibold)
                        Text("Hörproben, Qualität, Tempo, Downloads und eigene Stimmen an einem Ort.")
                            .flowFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Galerie öffnen") { galleryMode = GalleryRequest(languageCode: nil) }
                        .buttonStyle(.flowProminent)
                }
                .padding(18)
                .flowSurface(cornerRadius: Theme.Radius.row)
            }

            PillSection("Eigene Stimmen") {
                PillRow(title: "Klon-Engine", subtitle: "Liest mit deiner eigenen Stimme vor — läuft vollständig lokal.") {
                    Text(verbatim: "OmniVoice").flowFont(.callout, weight: .semibold)
                }
                PillRow(title: "Eigene Stimme anlegen", subtitle: "10–20 Sekunden ins Mikrofon sprechen oder eine Audiodatei importieren.") {
                    Button("Stimme anlegen …") { galleryMode = GalleryRequest(languageCode: nil) }
                        .buttonStyle(.flowSecondary)
                }
            }

            PillSection("Hörprobe") {
                PillRow(title: "Länge der Hörprobe", subtitle: "Wie viele Sätze die Probe in der Galerie und Prüfung vorliest.") {
                    PillStepper(value: $store.settings.voicePreviewSentenceCount, range: 1...8, suffix: "Sätze")
                }
                PillRow(title: "Maximale Zeichen", subtitle: "Obergrenze für lange Sätze in der Hörprobe.") {
                    PillStepper(value: $store.settings.voicePreviewMaxCharacters, range: 40...1200, step: 20)
                }
            }
        }
        .sheet(item: $galleryMode) { _ in
            VoiceGalleryView(onSelect: nil, currentVoice: nil)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            if info["gallery"] == "open" { galleryMode = GalleryRequest(languageCode: nil) }
            if info["gallery"] == "close" { galleryMode = nil }
        }
        #endif
    }
}

/// Default voice: name, quality/tempo, quick preview and direct choice.
private struct DefaultVoiceCard: View {
    let language: String
    let flag: String
    @Binding var voice: VoiceID
    let languageCode: String
    var onOpenGallery: () -> Void

    @StateObject private var preview = VoicePreviewPlayer()
    @Environment(SettingsStore.self) private var settingsStore

    private var profile: VoiceProfile? { VoiceCatalog.profile(for: voice) }
    private var candidates: [VoiceProfile] {
        VoiceCatalog.allProfiles.filter { $0.languageCode.hasPrefix(languageCode) }
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(flag)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Standardstimme \(L(language))")
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(profile?.displayName ?? voice.voice)
                    .flowFont(.title3)
                HStack(spacing: 6) {
                    if let profile {
                        StatusBadge(text: profile.gender.label, tint: .secondary)
                        StatusBadge(text: profile.speed.label, systemImage: "hare")
                        Text(String(repeating: "★", count: profile.quality.points) + String(repeating: "☆", count: max(0, 3 - profile.quality.points)))
                            .flowFont(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 12)
            Button {
                if let profile {
                    let settings = settingsStore.settings
                    preview.toggle(text: profile.sampleText, engineID: profile.id.engine, voice: profile.id.voice,
                                   speed: settings.defaultSpeed(for: profile.id.engine), settings: settings)
                }
            } label: {
                Image(systemName: preview.isPlaying || preview.isGenerating ? "stop.fill" : "play.fill")
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Hörprobe")
            Menu {
                ForEach(candidates) { candidate in
                    Button {
                        voice = candidate.id
                    } label: {
                        if candidate.id == voice {
                            Label(candidate.displayName, systemImage: "checkmark")
                        } else {
                            Text("\(candidate.displayName) · \(candidate.gender.label)")
                        }
                    }
                }
                Divider()
                Button("In der Galerie durchhören …", action: onOpenGallery)
            } label: {
                Text("Ändern")
                    .flowFont(.body, weight: .semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.tint.opacity(0.13)))
                    .foregroundStyle(.tint)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(18)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - Speech flow

private struct SpeechSettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Pausen", footer: "Die App plant Pausen an Satz-, Absatz- und Überschriftengrenzen und legt die Stille selbst in die Audiodaten — Mitlesen und Kapitelmarken bleiben exakt.") {
                pauseRow("Zwischen Sätzen", "0 = natürliche Pause der Engine", $store.settings.sentencePauseMs, 0...2000)
                pauseRow("Nach Absätzen", nil, $store.settings.paragraphPauseMs, 0...2000)
                pauseRow("Nach Überschriften", nil, $store.settings.headingPauseMs, 0...3000)
                pauseRow("Nach Listenpunkten", nil, $store.settings.listItemPauseMs, 0...2000)
                pauseRow("Nach Bildbeschreibungen", nil, $store.settings.figurePauseMs, 0...3000)
                pauseRow("Kapitelanfang (Vorlauf)", nil, $store.settings.chapterLeadInMs, 0...3000)
                pauseRow("Kapitelende (Auslauf)", nil, $store.settings.chapterTailMs, 0...5000)
                PillRow(title: "Menschliche Abweichung", subtitle: "Pausen schwanken leicht, damit es nicht maschinell klingt.") {
                    PillStepper(value: $store.settings.pauseJitterPercent, range: 0...50, step: 5, suffix: "%")
                }
            }

            PillSection("Tempo je Engine") {
                speedRow("Kokoro (Englisch)", $store.settings.kokoroSpeed, 0.5...2.0)
                speedRow("Kokoro Deutsch", $store.settings.kokoroGermanSpeed, 0.5...2.0)
                speedRow("Kokoro Thorsten", $store.settings.kokoroThorstenSpeed, 0.5...2.0)
                speedRow("Piper", $store.settings.piperSpeed, 0.5...2.0)
                speedRow("Supertonic", $store.settings.supertonicSpeed, 0.7...2.0)
            }

            PillSection("Klang", footer: "„Lebendigkeit“ steuert, wie stark Satzrhythmus und Aussprache variieren. Höher = ausdrucksstärker, aber weniger vorhersehbar.") {
                PillRow(title: "Piper · Lebendigkeit (Prosodie)") {
                    PillSlider(value: $store.settings.piperNoiseScale, range: 0.1...1.5, step: 0.01)
                }
                PillRow(title: "Piper · Lebendigkeit (Aussprache)") {
                    PillSlider(value: $store.settings.piperNoiseW, range: 0.1...1.5, step: 0.01)
                }
                PillRow(title: "Supertonic · Pause zwischen Segmenten") {
                    PillSlider(value: $store.settings.supertonicPauseSeconds, range: 0...1, step: 0.05, format: "%.2f s")
                }
            }
        }
    }

    private func pauseRow(_ title: String, _ subtitle: String?, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        PillRow(title: title, subtitle: subtitle) {
            PillStepper(value: value, range: range, step: 50, suffix: "ms")
        }
    }

    private func speedRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        PillRow(title: title) {
            PillSlider(value: value, range: range, step: 0.05, format: "%.2f×")
        }
    }
}

// MARK: - Output

private struct OutputSettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var showFolderPicker = false

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Format") {
                PillRow(title: "Standardformat", subtitle: "M4B ist ein Hörbuch mit Kapitelmarken in einer Datei.") {
                    PillPicker(selection: $store.settings.defaultOutputFormat,
                               options: OutputFormat.allCases.map { PillOption(value: $0, label: $0.displayName) })
                }
                PillRow(title: "AAC-Bitrate", subtitle: "Für M4B/M4A.") {
                    PillStepper(value: $store.settings.aacBitrateKbps, range: 64...320, step: 16, suffix: "kbit/s")
                }
                PillRow(title: "MP3-Qualität", subtitle: "0 = höchste Qualität, 9 = kleinste Dateien.") {
                    PillStepper(value: $store.settings.mp3Quality, range: 0...9)
                }
                PillRow(title: "Kapitel-Audio (Zwischenspeicher)", subtitle: "Bitrate der einzelnen Kapiteldateien.") {
                    PillStepper(value: $store.settings.chapterAudioBitrateKbps, range: 32...256, step: 16, suffix: "kbit/s")
                }
            }

            PillSection("Lautheit") {
                PillRow(title: "Lautheit normalisieren", subtitle: "Gleich laute Kapitel, keine Sprünge zwischen Stimmen.") {
                    PillToggle(isOn: $store.settings.loudnessNormalizationEnabled)
                }
                if settingsStore.settings.loudnessNormalizationEnabled {
                    PillRow(title: "Ziel-Lautheit") {
                        PillSlider(value: $store.settings.loudnessTargetLUFS, range: -30 ... -10, step: 0.5, format: "%.1f LUFS")
                    }
                    PillRow(title: "True Peak") {
                        PillSlider(value: $store.settings.loudnessTruePeakDB, range: -6 ... 0, step: 0.5, format: "%.1f dB")
                    }
                    PillRow(title: "Loudness Range") {
                        PillSlider(value: $store.settings.loudnessRangeLU, range: 1...20, step: 0.5, format: "%.1f LU")
                    }
                }
            }

            PillSection("Ablage") {
                PillRow(title: "Zielordner", subtitle: settingsStore.settings.outputBaseFolderPath.isEmpty ? "Standard: ~/Documents/Audiobooks" : settingsStore.settings.outputBaseFolderPath) {
                    Button("Wählen …") { showFolderPicker = true }
                        .buttonStyle(.flowSecondary)
                }
                PillRow(title: "Unterordner") {
                    PillPicker(selection: $store.settings.outputFolderTemplate,
                               options: OutputFolderTemplate.allCases.map { PillOption(value: $0, label: $0.displayName) })
                }
                PillRow(title: "Kapitel-Audio behalten", subtitle: "Sonst wird es nach geprüfter Verpackung gelöscht (spart Platz).") {
                    PillToggle(isOn: $store.settings.keepChapterAudioAfterPackaging)
                }
            }
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                settingsStore.settings.outputBaseFolderPath = url.path
            }
        }
    }
}

// MARK: - Text preparation

private struct TextSettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Bereinigung") {
                PillRow(title: "Kopf- und Fußzeilen entfernen", subtitle: "Wiederkehrende Seitentitel und Seitenzahlen.") {
                    PillToggle(isOn: $store.settings.stripRecurringHeadersFooters)
                }
                PillRow(title: "Fußnoten einbeziehen") {
                    PillToggle(isOn: $store.settings.includeFootnotes)
                }
                PillRow(title: "Literaturverzeichnis & Danksagungen auslassen") {
                    PillToggle(isOn: $store.settings.excludeBackMatterSections)
                }
                PillRow(title: "Kästen (Merke, Klinischer Fall …)") {
                    SegmentedPills(selection: $store.settings.boxLabelHandling, options: [
                        PillOption(value: BoxLabelHandling.remove, label: "Entfernen"),
                        PillOption(value: BoxLabelHandling.keep, label: "Behalten"),
                        PillOption(value: BoxLabelHandling.spoken, label: "Vorlesen"),
                    ])
                }
                PillRow(title: "Nummern vor Überschriften vorlesen", subtitle: "„2.3 Diagnostik“ statt „Diagnostik“.") {
                    PillToggle(isOn: $store.settings.speakHeadingNumbers)
                }
            }

            PillSection("Kapitel") {
                PillRow(title: "Standard-Dokumenttyp", subtitle: settingsStore.settings.defaultDocumentType.explanation) {
                    SegmentedPills(selection: $store.settings.defaultDocumentType,
                                   options: DocumentType.allCases.map { PillOption(value: $0, label: $0.displayName, systemImage: $0.systemImage) })
                }
                PillRow(title: "Mindestgröße pro Kapitel", subtitle: "Kürzere Abschnitte werden mit dem vorherigen zusammengeführt (Typ „Allgemein“).") {
                    PillStepper(value: $store.settings.minimumChapterCharacters, range: 0...5000, step: 100, suffix: "Zeichen")
                }
                PillRow(title: "Ziel-Kapitelgröße", subtitle: "Richtwert beim Bündeln zu Hörbuch-Tracks.") {
                    PillStepper(value: $store.settings.targetChapterCharacters, range: 2000...60000, step: 1000, suffix: "Zeichen")
                }
                PillRow(title: "Ohne Inhaltsverzeichnis automatisch teilen", subtitle: "Teilt an Absatzgrenzen in etwa gleich große Kapitel.") {
                    PillToggle(isOn: $store.settings.autoSplitEnabled)
                }
                if settingsStore.settings.autoSplitEnabled {
                    PillRow(title: "Zielgröße beim Teilen") {
                        PillStepper(value: $store.settings.autoSplitTargetCharacters, range: 3000...60000, step: 1000, suffix: "Zeichen")
                    }
                }
            }

            PillSection("Feinabstimmung je Dokumenttyp") {
                tuningRow("Buch", $store.settings.bookTuning)
                tuningRow("Paper", $store.settings.paperTuning)
                tuningRow("Report", $store.settings.reportTuning)
            }
        }
    }

    private func tuningRow(_ title: String, _ tuning: Binding<DocumentTypeTuning>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(title)).flowFont(.body, weight: .semibold)
            HStack {
                Text("Mindestgröße pro Kapitel").flowFont(.callout).foregroundStyle(.secondary)
                Spacer()
                PillStepper(value: tuning.minimumChapterCharacters, range: 0...5000, step: 50, suffix: "Zeichen")
            }
            HStack {
                Text("Zusammenfassungs-Budget je Aufruf").flowFont(.callout).foregroundStyle(.secondary)
                Spacer()
                PillStepper(value: tuning.summarizationChunkCharacterBudget, range: 10000...150000, step: 5000, suffix: "Zeichen")
            }
        }
        .padding(18)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }
}

// MARK: - AI

private struct AISettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            LLMSettingsTabView()

            PillSection("KI-Gliederung & Zusammenfassung") {
                PillRow(title: "Mindestlänge KI-Kapitel") {
                    PillStepper(value: $store.settings.minAIChapterCharacters, range: 0...12000, step: 100, suffix: "Zeichen")
                }
                PillRow(title: "Maximale KI-Kapitellänge", subtitle: "0 = aus") {
                    PillStepper(value: $store.settings.aiChapterMaxCharacters, range: 0...60000, step: 1000, suffix: "Zeichen")
                }
                PillRow(title: "Übergangskontext zwischen Aufrufen", subtitle: "Gibt dem Modell das Ende des vorherigen Abschnitts mit.") {
                    PillToggle(isOn: $store.settings.aiChapterContinuityEnabled)
                }
                PillRow(title: "Zusammenfassungs-Budget (Allgemein)", subtitle: "Zeichen pro Aufruf.") {
                    PillStepper(value: $store.settings.summarizationChunkCharacterBudget, range: 10000...150000, step: 5000)
                }
                PillRow(title: "Toleranz beim Bündeln") {
                    PillSlider(value: $store.settings.summarizationBatchTolerance, range: 0...0.5, step: 0.01, format: "%.2f")
                }
            }

            PillSection("Vorlagen") {
                PromptsSettingsTabView()
            }
        }
    }
}

// MARK: - Engines

private struct EnginesSettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Energie", footer: "Netzteil und Batterie getrennt. Maximal nutzt alle Worker und die schnellen Kerne; Stromsparend rendert mit einem Worker auf den Effizienzkernen, hält weniger Speicher und lässt Szenen ruhen. Der macOS-Stromsparmodus schaltet immer auf Stromsparend.") {
                PillRow(title: "Am Netzteil", subtitle: store.settings.powerModeOnAdapter.summary) {
                    SegmentedPills(selection: $store.settings.powerModeOnAdapter,
                                   options: PowerMode.allCases.map { PillOption(value: $0, label: $0.displayName) }, size: .small)
                }
                PillRow(title: "Im Akkubetrieb", subtitle: store.settings.powerModeOnBattery.summary) {
                    SegmentedPills(selection: $store.settings.powerModeOnBattery,
                                   options: PowerMode.allCases.map { PillOption(value: $0, label: $0.displayName) }, size: .small)
                }
                PillRow(title: "Gerade aktiv", subtitle: PowerMonitor.shared.systemLowPower ? L("macOS-Stromsparmodus ist an") : nil) {
                    Text(verbatim: "\(PowerMonitor.shared.onAdapter ? L("Netzteil") : L("Batterie")) · \(PowerMonitor.shared.mode(for: store.settings).displayName)")
                        .flowFont(.callout, weight: .semibold)
                }
            }

            PillSection("Allgemein") {
                PillRow(title: "Fallback-Engine", subtitle: "Für neue Importe, wenn keine Standardstimme der Sprache greift.") {
                    PillPicker(selection: $store.settings.ttsEngine,
                               options: TTSEngineID.allCases.map { PillOption(value: $0, label: $0.shortName) })
                }
                PillRow(title: "Parallele Audio-Worker", subtitle: "Kapitel, die gleichzeitig gerendert werden. Auf Apple Silicon sind 2 meist optimal.") {
                    PillStepper(value: $store.settings.ttsParallelWorkers, range: 1...4)
                }
            }

            PillSection("Speicher-Schutz & RAM-Watchdog", footer: "Überwacht den Arbeitsspeicher während der Audio-Synthese (inklusive aller Hintergrund-Worker), um macOS vor Überlastung zu schützen.") {
                PillRow(title: "RAM-Watchdog aktiv", subtitle: "Pausiert die Synthese kontrolliert, falls der Speicherverbrauch das Limit überschreitet.") {
                    PillToggle(isOn: $store.settings.ramWatchdogEnabled)
                }
                if store.settings.ramWatchdogEnabled {
                    PillRow(title: "Modus", subtitle: store.settings.ramWatchdogAuto ? "Passt das Limit automatisch an die gewählte Engine und Worker-Anzahl an (z. B. OmniVoice ~4,1 GB pro Worker)." : "Festes manuelles Limit für alle Engines.") {
                        SegmentedPills(
                            selection: $store.settings.ramWatchdogAuto,
                            options: [
                                PillOption(value: true, label: "Automatisch"),
                                PillOption(value: false, label: "Manuell")
                            ],
                            size: .small
                        )
                    }
                    if !store.settings.ramWatchdogAuto {
                        PillRow(title: "Manuelles RAM-Limit", subtitle: "\(Int(store.settings.ramWatchdogManualLimitGB)) GB Höchstgrenze für den gesamten Syntheseprozess.") {
                            PillStepper(
                                value: Binding(
                                    get: { Int(store.settings.ramWatchdogManualLimitGB) },
                                    set: { store.settings.ramWatchdogManualLimitGB = Double($0) }
                                ),
                                range: 4...32,
                                step: 1
                            )
                        }
                    } else {
                        let currentEngine = store.settings.ttsEngine
                        let workers = store.settings.ttsParallelWorkers
                        let autoLimit = store.settings.autoRAMLimitGB(for: currentEngine, workers: workers)
                        PillRow(title: "Aktives Auto-Limit", subtitle: "\(currentEngine.shortName) mit \(workers) \(workers == 1 ? "Worker" : "Workern")") {
                            Text(verbatim: "\(String(format: "%.1f", autoLimit)) GB")
                                .flowFont(.callout, weight: .semibold)
                        }
                    }
                }
            }

            PillSection("Kokoro") {
                PillRow(title: "Englische Standardstimme (Kokoro)") {
                    PillPicker(selection: $store.settings.kokoroVoice,
                               options: KokoroEngine.standardVoices.map { PillOption(value: $0.id, label: $0.displayName) })
                }
                PillRow(title: "Deutsche Stimme (Kokoro Deutsch)") {
                    SegmentedPills(selection: $store.settings.kokoroGermanVoice, options: [
                        PillOption(value: "martin", label: "Martin"),
                        PillOption(value: "victoria", label: "Victoria"),
                    ])
                }
                ModelStatusCard(title: "Kokoro Deutsch — Modelle") {
                    GermanKokoroModelManagerView(voices: ["martin", "victoria", "thorsten"])
                }
                PillRow(title: "Modell-Repository", subtitle: "mlx-audio / Hugging Face") {
                    TextField("Repo", text: $store.settings.kokoroModelRepo)
                        .textFieldStyle(.flow)
                        .frame(width: 280)
                }
            }

            PillSection("Piper") {
                PillRow(title: "Standardstimme (Piper)") {
                    PillPicker(selection: $store.settings.piperVoice,
                               options: PiperVoiceCatalog.allVoices.map { PillOption(value: $0.id, label: $0.displayName) })
                }
                ModelStatusCard(title: "Piper-Stimmen") {
                    PiperVoiceManagerView()
                }
            }

            PillSection("Supertonic 3") {
                PillRow(title: "Standardstimme (Supertonic)") {
                    PillPicker(selection: $store.settings.supertonicVoice,
                               options: SupertonicEngine(settings: settingsStore.settings, environment: .shared).availableVoices().map { PillOption(value: $0.id, label: $0.displayName) })
                }
                PillRow(title: "Syntheseschritte") {
                    PillStepper(value: $store.settings.supertonicSteps, range: 1...20)
                }
                PillRow(title: "Zeichen pro Segment") {
                    PillStepper(value: $store.settings.supertonicChunkCharacters, range: 40...300, step: 10)
                }
                ModelStatusCard(title: "Supertonic — Modell") {
                    SupertonicModelManagerView()
                }
            }

            PillSection("OmniVoice", footer: "Mehrsprachiges Diffusionsmodell. Weniger Stufen = schneller, mehr = hochwertiger.") {
                PillRow(title: "Qualitätsstufen") {
                    PillStepper(value: $store.settings.omniVoiceSteps, range: 4...64, step: 4)
                }
                ModelStatusCard(title: "OmniVoice — Modell (2,04 GB)") {
                    SingleModelManagerView(modelID: "omnivoice-base")
                }
            }

            PillSection("macOS-Systemstimmen", footer: "Schnell, ohne Download in der App, mittlere Qualität. Bessere Stimmen (z. B. „Anna (Premium)“) lädst du in den Systemeinstellungen unter Bedienungshilfen → Gesprochene Inhalte → Systemstimme → Stimmen verwalten; nach einem Neustart der App erscheinen sie hier.") {
                PillRow(title: "Installiert", subtitle: AppleSpeechEngine.installedVoices().prefix(4).map { AppleSpeechEngine.label(for: $0) }.joined(separator: " · ")) {
                    Text(verbatim: "\(AppleSpeechEngine.installedVoices().count)").flowFont(.callout, weight: .semibold)
                }
                PillRow(title: "Premium-Stimmen laden") {
                    Button("Systemeinstellungen öffnen") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                }
            }
        }
    }
}

private struct ModelStatusCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(title)).flowFont(.body, weight: .medium)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }
}

extension TTSEngineID {
    /// Short engine names for pickers (the long names explain the runtime).
    var shortName: String {
        switch self {
        case .kokoro: return L("Kokoro (Englisch)")
        case .piper: return L("Piper")
        case .kokoroGerman: return L("Kokoro Deutsch")
        case .kokoroThorsten: return L("Kokoro Thorsten")
        case .supertonic3: return L("Supertonic 3")
        case .omniVoice: return L("OmniVoice")
        case .appleSystem: return L("macOS-Systemstimmen")
        }
    }
}

// MARK: - Appearance

/// Erscheinungsbild (plan 9.2) — mirrors the template one to one.
struct AppearanceSettingsSection: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Vorschau") {
                AppearancePreview()
            }

            PillSection("Sprache") {
                LanguageRow()
            }

            PillSection("Darstellung") {
                PillRow(title: "Erscheinungsbild", subtitle: "„System“ folgt der Einstellung deines Macs.") {
                    SegmentedPills(selection: $store.settings.appearanceMode, options: [
                        PillOption(value: AppearanceMode.system, label: "System", systemImage: "circle.lefthalf.filled"),
                        PillOption(value: AppearanceMode.light, label: "Hell", systemImage: "sun.max"),
                        PillOption(value: AppearanceMode.dark, label: "Dunkel", systemImage: "moon"),
                    ])
                }
                PillRow(title: "Textgröße", subtitle: "Eine feste Größe für die App. Symbole und Zeilen wachsen mit.") {
                    SegmentedPills(selection: $store.settings.textSizeStep,
                                   options: TextSizeStep.allCases.map { PillOption(value: $0, label: $0.displayName) },
                                   size: .small)
                }
            }

            PillSection("Akzentfarbe", footer: "Für Auswahl, Schalter, Fortschritt, Wiedergabe und den Farbverlauf hinter den Fenstern.") {
                AccentSwatchPicker(accent: $store.settings.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 18)
                    .flowSurface(cornerRadius: Theme.Radius.card)
            }

            PillSection("Flächen") {
                PillRow(title: "Glas", subtitle: SurfaceLevel(intensity: settingsStore.settings.glassIntensity).explanation) {
                    SegmentedPills(selection: Binding(
                        get: { SurfaceLevel(intensity: settingsStore.settings.glassIntensity) },
                        set: { settingsStore.settings.glassIntensity = $0.intensity }
                    ), options: SurfaceLevel.allCases.map { PillOption(value: $0, label: $0.displayName) })
                }
                PillRow(title: "Farbverlauf", subtitle: "Die weichen Farben hinter den Fenstern.") {
                    SegmentedPills(selection: $store.settings.flowBackgroundEnabled, options: [
                        PillOption(value: true, label: "An"),
                        PillOption(value: false, label: "Aus"),
                    ])
                }
                PillRow(title: "Bibliothek gruppieren nach", subtitle: "Gruppierung der Bücher in der Seitenleiste.") {
                    PillPicker(selection: $store.settings.sidebarGrouping,
                               options: SidebarGrouping.allCases.map { PillOption(value: $0, label: $0.displayName) })
                }
            }

            PillSection("Bewegung") {
                PillRow(title: "Übergänge & Ambiente", subtitle: "Farben fließen ineinander, Seiten blättern um. „Reduziert“ hält alles still.") {
                    SegmentedPills(selection: $store.settings.motionMode, options: [
                        PillOption(value: MotionMode.system, label: "Fließend", shortLabel: "Fließend"),
                        PillOption(value: MotionMode.reduced, label: "Reduziert"),
                        PillOption(value: MotionMode.off, label: "Aus"),
                    ])
                }
            }
        }
    }
}

/// Deutsch / English / System, applied on relaunch (macOS loads the app's
/// language at start); the restart button relaunches immediately.
private struct LanguageRow: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var launchedWith = AppLanguage.current

    private var pendingRestart: Bool {
        let chosen = settingsStore.settings.appLanguage
        let effective: String = {
            switch chosen {
            case .de: return "de"
            case .en: return "en"
            case .system: return Locale.preferredLanguages.first.map { $0.hasPrefix("de") ? "de" : "en" } ?? "en"
            }
        }()
        return effective != launchedWith
    }

    var body: some View {
        @Bindable var store = settingsStore
        PillRow(title: "App-Sprache", subtitle: pendingRestart ? "Wird nach dem Neustart übernommen." : "„System“ folgt der Sprache deines Macs.") {
            HStack(spacing: 10) {
                SegmentedPills(selection: $store.settings.appLanguage, options: [
                    PillOption(value: AppLanguage.system, label: "System", systemImage: "globe"),
                    PillOption(value: AppLanguage.de, label: "Deutsch", verbatim: true),
                    PillOption(value: AppLanguage.en, label: "English", verbatim: true),
                ])
                if pendingRestart {
                    Button("Neu starten") { relaunch() }
                        .buttonStyle(FlowButtonStyle(variant: .prominent, size: .small))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Theme.Motion.flow, value: pendingRestart)
        }
        .onChange(of: settingsStore.settings.appLanguage) { _, language in
            language.apply()
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Template preview row: three mode cards + one example setting.
private struct AppearancePreview: View {
    @State private var example = true

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                cards
            }
            PillRow(title: "Eine Einstellung", subtitle: "Jede Einstellung ist eine Pille: Text links, Steuerung rechts.") {
                PillToggle(isOn: $example)
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        previewCard("Hören", "Große Bühne mit Cover und Ambiente", "headphones", prominent: true)
        previewCard("Lesen", "Text als Buchseite, Satz für Satz", "text.book.closed", prominent: false)
        previewCard("Lernen", "Inhaltsverzeichnis und Text nebeneinander", "rectangle.split.3x1", prominent: false)
    }

    private func previewCard(_ title: String, _ subtitle: String, _ image: String, prominent: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: image)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
                .frame(width: 44, height: 44)
                .background(Circle().fill(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.14))))
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).flowFont(.body, weight: .semibold)
                Text(L(subtitle)).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .flowSurface(cornerRadius: Theme.Radius.card)
    }
}

// MARK: - Model managers (engines pane)

private struct GermanKokoroModelManagerView: View {
    let voices: [String]
    private let manager = GermanKokoroEnvironmentManager.shared
    @State private var installing: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(voices, id: \.self) { voice in
                HStack {
                    Text(voice.capitalized).flowFont(.body)
                    Spacer()
                    if manager.isVoiceReady(voice) {
                        StatusBadge(text: "Bereit", systemImage: "checkmark.circle.fill", tint: .green)
                    } else {
                        Button(installing == voice ? "Installiere …" : "Installieren") { install(voice) }
                            .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                            .disabled(installing != nil)
                    }
                }
            }
            if let message { Text(message).flowFont(.caption).foregroundStyle(.secondary) }
        }
    }

    private func install(_ voice: String) {
        installing = voice
        message = "Lade und konvertiere \(voice) …"
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
                StatusBadge(text: "Supertonic 3 bereit", systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                Button(installing ? "Installiere …" : "Modell und Laufzeit installieren") { install() }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                    .disabled(installing)
            }
            Spacer()
            if let message { Text(message).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    private func install() {
        installing = true
        message = "Lade Supertonic 3 …"
        Task {
            do {
                try await manager.install { line in Task { @MainActor in message = line } }
                installing = false
                message = "Supertonic 3 ist bereit."
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
                    Text(voice.displayName).flowFont(.body)
                    Spacer()
                    if let progress = downloadProgress[voice.id] {
                        ProgressRing(fraction: progress, lineWidth: 2.5).frame(width: 18, height: 18)
                    } else if isDownloaded(voice) {
                        StatusBadge(text: "Geladen", systemImage: "checkmark.circle.fill", tint: .green)
                    } else {
                        Button {
                            download(voice)
                        } label: {
                            Label("~60 MB", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                        .disabled(!environment.isEnvironmentReady())
                    }
                }
            }
            if !environment.isEnvironmentReady() {
                Text("Die Piper-Umgebung wird zuerst unter „Diagnose“ eingerichtet.")
                    .flowFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).flowFont(.caption).foregroundStyle(.red)
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
                downloadProgress[voice.id] = nil
                downloadedFlags[voice.id] = true
            } catch {
                downloadProgress[voice.id] = nil
                errorMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}

private struct SingleModelManagerView: View {
    let modelID: String
    private let manager = ModelManager.shared
    @State private var installing = false
    @State private var message: String?
    @State private var isReady = false

    private var item: ModelItem? {
        manager.availableModels.first { $0.id == modelID }
    }

    var body: some View {
        HStack {
            if isReady {
                StatusBadge(text: "Bereit", systemImage: "checkmark.circle.fill", tint: .green)
                Button("Entfernen") { delete() }
                    .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
            } else {
                Button(installing ? "Lade herunter …" : "Modell herunterladen (\(item?.sizeFormatted ?? ""))") {
                    install()
                }
                .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                .disabled(installing)
            }
            Spacer()
            if let message {
                Text(message).flowFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .onAppear { updateReady() }
    }

    private func updateReady() {
        if let item { isReady = manager.isInstalled(item) }
    }

    private func install() {
        guard let item else { return }
        installing = true
        message = "Starte Download …"
        Task {
            do {
                try await manager.install(item) { line in
                    Task { @MainActor in message = line }
                }
                installing = false
                updateReady()
                message = "\(item.title) ist bereit."
            } catch {
                installing = false
                updateReady()
                message = error.localizedDescription
            }
        }
    }

    private func delete() {
        guard let item else { return }
        try? manager.delete(item)
        updateReady()
        message = "Modell entfernt."
    }
}

