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
        ("Stimmen", ["defaultVoiceDE", "defaultVoiceEN", "defaultVoicesByLanguage", "preferredCloneEngine", "voicePreviewSentenceCount", "voicePreviewMaxCharacters", "autoSelectEngineByLanguage", "ttsEngine", "phononVoice", "pocketVoice", "kokoroVoice", "piperVoice", "kokoroGermanVoice", "supertonicVoice"]),
        ("Sprechfluss", ["sentencePauseMs", "paragraphPauseMs", "headingPauseMs", "listItemPauseMs", "figurePauseMs", "chapterLeadInMs", "chapterTailMs", "pauseJitterPercent", "naturalPauseRhythm", "pauseVariationMs", "kokoroSpeed", "kokoroGermanSpeed", "kokoroThorstenSpeed", "piperSpeed", "piperNoiseScale", "piperNoiseW", "supertonicSpeed", "supertonicPauseSeconds", "phononSpeed", "phononTemperature", "pocketTemperature", "phononEnglish31m", "phononRefinementSteps", "pocketHighQuality", "supertonicSteps", "supertonicChunkCharacters", "omniVoiceSteps"]),
        ("Ausgabe", ["defaultOutputFormat", "outputBaseFolderPath", "outputFolderTemplate", "mp3Quality", "aacBitrateKbps", "loudnessNormalizationEnabled", "loudnessMode", "audioEnhancementEnabled", "audioDefaultsRevision", "loudnessTargetLUFS", "loudnessTruePeakDB", "loudnessRangeLU", "keepChapterAudioAfterPackaging"]),
        ("Textaufbereitung", ["stripRecurringHeadersFooters", "includeFootnotes", "minimumChapterCharacters", "targetChapterCharacters", "excludeBackMatterSections", "defaultDocumentType", "bookTuning", "paperTuning", "reportTuning", "autoSplitEnabled", "autoSplitTargetCharacters", "boxLabelHandling", "speakHeadingNumbers"]),
        ("KI & Zusammenfassung", ["llmProvider", "llmBaseURL", "llmAPIKey", "llmModel", "omlxBaseURL", "omlxAPIKey", "omlxModel", "omlxGeneration", "lmStudioGeneration", "llmContextLimitTokens", "llmRequestTimeoutSeconds", "llmConnectionTimeoutSeconds", "correctImplausibleServerPresets", "autoStartOMLX", "autoUnloadOMLXAfterPass", "promptTemplates", "summarizationChunkCharacterBudget", "aiChapterMaxCharacters", "minAIChapterCharacters", "aiChapterContinuityEnabled", "summarizationBatchTolerance"]),
        ("Bilder", ["llmVisionTimeoutSeconds", "llmVisionThinkingMode", "llmVisionModelOverride", "describeImagesWithVisionModel", "minimumImageDimensionForVisionPass", "imageDescriptionScope", "minimumImageAreaPercent", "minimumImageKilobytes", "maximumImageAspectRatio", "detectVectorFigures", "removeFigureLabelText", "keepFigureCaptions", "removeCrossReferences", "imageDescriptionLabel"]),
        ("Erscheinungsbild", ["appearanceMode", "textSizeStep", "accent", "glassIntensity", "motionMode", "flowBackgroundEnabled", "sidebarGrouping", "appLanguage", "soundEffectsEnabled", "owlPostEnabled", "loadingQuipsEnabled", "lesserDogEnabled", "pixelMode", "unlockedAchievements", "dogPets"]),
        ("Engines & Downloads", []),
        ("Leistung", ["powerModeOnAdapter", "powerModeOnBattery", "ttsParallelWorkers", "ttsWorkersByEngine", "omlxParallelRequests", "lmStudioParallelRequests", "visionParallelRequests", "ramWatchdog", "ramWatchdogEnabled", "ramWatchdogAuto", "ramWatchdogManualLimitGB", "speicher"]),
        ("Diagnose", ["dependencyPathOverrides", "kokoroModelRepo"]),
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
        ScrollViewReader { proxy in
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
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
            if let section = (note.userInfo as? [String: String])?["scrollTo"] { proxy.scrollTo(section, anchor: .top) }
        }
        #endif
        }
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
        case .performance: PerformanceSettingsPane()
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
                    .appFont(size: 30, weight: .semibold, design: .serif)
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
                ForEach(["fr", "es", "it"], id: \.self) { code in
                    DefaultVoiceCard(language: languageDisplayName(code), flag: code.uppercased(), voice: Binding(
                        get: { store.settings.defaultVoiceID(forLanguage: code) },
                        set: { store.settings.defaultVoicesByLanguage[code] = $0 }
                    ), languageCode: code) {
                        galleryMode = GalleryRequest(languageCode: code)
                    }
                }
                DefaultVoiceCard(language: "Andere Sprachen", flag: "··", voice: Binding(
                    get: { store.settings.fallbackVoice },
                    set: { store.settings.setFallbackVoice($0) }
                ), languageCode: nil, title: L("Für andere Sprachen")) {
                    galleryMode = GalleryRequest(languageCode: nil)
                }
                PillRow(title: "Engine nach Sprache wählen", subtitle: "Erkennt die Buchsprache und nimmt die passende Standardstimme; aus = immer die Stimme für andere Sprachen.") {
                    PillToggle(isOn: $store.settings.autoSelectEngineByLanguage)
                }
            }

            PillSection("Stimmen-Galerie") {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .appFont(size: 26)
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
                PillRow(title: "Klon-Engine", subtitle: "Liest mit deiner eigenen Stimme vor — läuft vollständig lokal. Pocket TTS ist deutlich schneller, OmniVoice kann mehr Sprachen.") {
                    SegmentedPills(selection: $store.settings.preferredCloneEngine, options: [
                        PillOption(value: TTSEngineID.pocketTTS, label: "Pocket TTS", verbatim: true),
                        PillOption(value: TTSEngineID.omniVoice, label: "OmniVoice", verbatim: true),
                    ], size: .small)
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
        .sheet(item: $galleryMode) { request in
            VoiceGalleryView(onSelect: nil, currentVoice: nil, languageCode: request.languageCode)
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
    /// nil = the fallback for other languages (choices from every language).
    let languageCode: String?
    var title: String? = nil
    var onOpenGallery: () -> Void

    @StateObject private var preview = VoicePreviewPlayer()
    @Environment(SettingsStore.self) private var settingsStore

    private var profile: VoiceProfile? { VoiceCatalog.profile(for: voice) }
    private var candidates: [VoiceProfile] {
        // The recommended voices (plus the current one); everything else
        // lives in the gallery.
        VoiceCatalog.profiles(language: languageCode ?? "de").filter { $0.featured || $0.id == voice }
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(flag)
                .appFont(size: 13, weight: .heavy, design: .rounded)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title ?? String(format: L("Standardstimme %@"), L(language)))
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(profile?.displayName ?? voice.voice)
                    .flowFont(.title3)
                if let profile {
                    let stars = Text(String(repeating: "★", count: profile.quality.points) + String(repeating: "☆", count: max(0, 3 - profile.quality.points)))
                        .flowFont(.caption)
                        .foregroundStyle(.orange)
                    // Narrow windows (v4.1): drop badges instead of overflowing.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            StatusBadge(text: profile.gender.label, tint: .secondary)
                            StatusBadge(text: profile.speed.label, systemImage: "hare")
                            stars
                        }
                        HStack(spacing: 6) {
                            StatusBadge(text: profile.speed.label, systemImage: "hare")
                            stars
                        }
                        stars
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
                if languageCode == nil {
                    ForEach(VoiceCatalog.galleryLanguages, id: \.self) { code in
                        Menu(languageDisplayName(code)) {
                            ForEach(VoiceCatalog.profiles(language: code).filter(\.featured)) { candidate in
                                candidateButton(candidate)
                            }
                        }
                    }
                } else {
                    ForEach(candidates) { candidate in candidateButton(candidate) }
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

    private func candidateButton(_ candidate: VoiceProfile) -> some View {
        Button {
            voice = candidate.id
        } label: {
            if candidate.id == voice {
                Label(candidate.displayName, systemImage: "checkmark")
            } else {
                Text(verbatim: "\(candidate.displayName) · \(candidate.gender.label) · \(candidate.id.engine.shortName)")
            }
        }
    }
}

// MARK: - Speech flow

private struct SpeechSettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Pausen", footer: "Die App plant Pausen an Satz-, Absatz- und Überschriftengrenzen und legt die Stille selbst in die Audiodaten — Mitlesen und Kapitelmarken bleiben exakt.") {
                pauseRow("Zwischen Sätzen", "0 = natürliche Pause der Engine (im natürlichen Rhythmus mindestens 160 ms)", $store.settings.sentencePauseMs, 0...2000)
                pauseRow("Nach Absätzen", nil, $store.settings.paragraphPauseMs, 0...2000)
                pauseRow("Nach Überschriften", nil, $store.settings.headingPauseMs, 0...3000)
                pauseRow("Nach Listenpunkten", nil, $store.settings.listItemPauseMs, 0...2000)
                pauseRow("Nach Bildbeschreibungen", nil, $store.settings.figurePauseMs, 0...3000)
                pauseRow("Kapitelanfang (Vorlauf)", nil, $store.settings.chapterLeadInMs, 0...3000)
                pauseRow("Kapitelende (Auslauf)", nil, $store.settings.chapterTailMs, 0...5000)
                PillRow(title: "Natürlicher Sprechrhythmus", subtitle: "Pausen folgen dem Text: länger nach „…“, Fragen, langen Sätzen und vor wörtlicher Rede, kürzer nach kurzen Sätzen.") {
                    PillToggle(isOn: $store.settings.naturalPauseRhythm)
                }
                if store.settings.naturalPauseRhythm {
                    PillRow(title: "Schwankung um den Zielwert", subtitle: "Jede Pause weicht bis zu so viel nach oben oder unten ab (zwischen Sätzen die Hälfte).") {
                        PillStepper(value: $store.settings.pauseVariationMs, range: 0...2000, step: 50, suffix: "± ms")
                    }
                }
                PillRow(title: "Menschliche Abweichung", subtitle: "Pausen schwanken leicht, damit es nicht maschinell klingt.") {
                    PillStepper(value: $store.settings.pauseJitterPercent, range: 0...50, step: 5, suffix: "%")
                }
                PillRow(title: "Supertonic · Pause zwischen Segmenten", subtitle: "Supertonic spricht in festen Textstücken; diese Stille kommt dazwischen.") {
                    PillSlider(value: $store.settings.supertonicPauseSeconds, range: 0...1, step: 0.05, format: "%.2f s")
                }
            }

            PillSection("Tempo je Engine") {
                speedRow("Kokoro (EN, FR, ES, IT)", $store.settings.kokoroSpeed, 0.5...2.0)
                speedRow("Kokoro Deutsch", $store.settings.kokoroGermanSpeed, 0.5...2.0)
                speedRow("Kokoro Thorsten", $store.settings.kokoroThorstenSpeed, 0.5...2.0)
                speedRow("Piper", $store.settings.piperSpeed, 0.5...2.0)
                speedRow("Supertonic", $store.settings.supertonicSpeed, 0.7...2.0)
                speedRow("Phonon", $store.settings.phononSpeed, 0.75...1.5)
            }

            PillSection("Ausdruck je Engine", footer: "Wie lebendig die Stimme spricht: ruhiger = gleichmäßiger und vorhersehbarer, lebendiger = mehr Betonung und Abwechslung, aber auch mehr Ausrutscher. Die Mitte ist die Empfehlung der Entwickler. Kokoro, Supertonic und die Systemstimmen haben keinen solchen Regler. Abweichend vom Standard spricht Phonon auch im Stromsparmodus über die CPU statt die Neural Engine.") {
                ExpressionRow(engine: .phonon, value: $store.settings.phononTemperature,
                              range: ExpressionDefaults.temperatureRange, standard: ExpressionDefaults.temperature)
                ExpressionRow(engine: .pocketTTS, value: $store.settings.pocketTemperature,
                              range: ExpressionDefaults.temperatureRange, standard: ExpressionDefaults.temperature)
                ExpressionRow(engine: .piper, value: Binding(
                    get: { store.settings.piperNoiseScale },
                    set: {
                        store.settings.piperNoiseScale = $0
                        store.settings.piperNoiseW = ExpressionDefaults.piperNoiseW(forNoiseScale: $0)
                    }
                ), range: ExpressionDefaults.piperNoiseScaleRange, standard: ExpressionDefaults.piperNoiseScale)
            }

            PillSection("Modelle je Engine", footer: "Englisch spricht Phonon wahlweise mit dem 40M-Modell (nur nicht-kommerziell, Hugging-Face-Anmeldung) oder dem 31M-Modell (Apache 2.0, ohne Anmeldung, rund 5 % schneller). Das gewählte Modell lädst du in der Stimmen-Galerie oder unter Engines & Downloads.") {
                PillRow(title: "Phonon · Englisch-Modell") {
                    SegmentedPills(selection: $store.settings.phononEnglish31m, options: [
                        PillOption(value: false, label: "40M"),
                        PillOption(value: true, label: "31M · Apache 2.0"),
                    ], size: .small)
                }
            }

            PillSection("Qualität je Engine", footer: "Mehr Qualität kostet Rechenzeit. Die nötigen Modelle lädst du in der Stimmen-Galerie oder unter Engines & Downloads.") {
                PillRow(title: "Phonon · Verfeinerungsschritte", subtitle: "Mehr Schritte klingen etwas feiner und kosten 15–30 % Tempo. Über 1 nutzt Phonon die Neural Engine nicht.") {
                    SegmentedPills(selection: $store.settings.phononRefinementSteps, options: [
                        PillOption(value: 1, label: "1"),
                        PillOption(value: 2, label: "2"),
                        PillOption(value: 4, label: "4"),
                    ], size: .small)
                }
                PillRow(title: "Pocket TTS · Hohe Qualität (24 Schichten)", subtitle: "Natürlicher, aber etwa dreimal langsamer und 2,4 GB Arbeitsspeicher je Worker. Braucht das 24-Schichten-Modell der Sprache.") {
                    PillToggle(isOn: $store.settings.pocketHighQuality)
                }
                PillRow(title: "Supertonic · Syntheseschritte", subtitle: "Mehr Schritte = sauberer, langsamer.") {
                    PillStepper(value: $store.settings.supertonicSteps, range: 1...20)
                }
                PillRow(title: "Supertonic · Zeichen pro Segment") {
                    PillStepper(value: $store.settings.supertonicChunkCharacters, range: 40...300, step: 10)
                }
                PillRow(title: "OmniVoice · Qualitätsstufen", subtitle: "Weniger Stufen = schneller, mehr = hochwertiger.") {
                    PillStepper(value: $store.settings.omniVoiceSteps, range: 4...64, step: 4)
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
                PillRow(title: "AAC-Bitrate", subtitle: "Für M4B/M4A. Sprache in Mono braucht selten mehr als 128 kbit/s.") {
                    PillStepper(value: $store.settings.aacBitrateKbps, range: 64...320, step: 16, suffix: "kbit/s")
                }
                PillRow(title: "MP3-Qualität", subtitle: "0 = höchste Qualität, 9 = kleinste Dateien.") {
                    PillStepper(value: $store.settings.mp3Quality, range: 0...9)
                }
            }

            PillSection("Aufbereitung", footer: "Entfernt Klicks, rauscht leicht ab und hebt die Präsenz über 5 kHz um 2 dB an. Hilft vor allem Phonon, das etwas dumpf klingt. Kostet rund 3 Sekunden Rechenzeit pro 10 Minuten Audio.") {
                PillRow(title: "Klang aufbereiten") {
                    PillToggle(isOn: $store.settings.audioEnhancementEnabled)
                }
            }

            PillSection("Lautheit") {
                PillRow(title: "Lautheit normalisieren", subtitle: "Gleich laute Kapitel, keine Sprünge zwischen Stimmen.") {
                    PillToggle(isOn: $store.settings.loudnessNormalizationEnabled)
                }
                if settingsStore.settings.loudnessNormalizationEnabled {
                    PillRow(title: "Verfahren", subtitle: settingsStore.settings.loudnessMode == .calm
                            ? "Ein fester Pegel pro Kapitel, nur Spitzen werden sanft begrenzt. Die Stimme bleibt, wie die Engine sie erzeugt."
                            : "Regelt die Lautstärke laufend nach (EBU R128, wie vor 4.4). Gleichmäßiger, kann aber dumpfer klingen.") {
                        SegmentedPills(selection: $store.settings.loudnessMode,
                                       options: LoudnessMode.allCases.map { PillOption(value: $0, label: $0.displayName) }, size: .small)
                    }
                    PillRow(title: "Ziel-Lautheit") {
                        PillSlider(value: $store.settings.loudnessTargetLUFS, range: -30 ... -10, step: 0.5, format: "%.1f LUFS")
                    }
                    PillRow(title: "True Peak") {
                        PillSlider(value: $store.settings.loudnessTruePeakDB, range: -6 ... 0, step: 0.5, format: "%.1f dB")
                    }
                    if settingsStore.settings.loudnessMode == .dynamic {
                        PillRow(title: "Loudness Range") {
                            PillSlider(value: $store.settings.loudnessRangeLU, range: 1...20, step: 0.5, format: "%.1f LU")
                        }
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

// MARK: - Performance

/// Leistung (v4): energy modes, parallelism of every engine, the LLM and
/// the vision model side by side, and the RAM watchdog.
private struct PerformanceSettingsPane: View {
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

            PillSection("Parallelität", footer: "Wie viele Kapitel je Engine gleichzeitig gesprochen werden. Startwerte aus Messungen auf Apple Silicon; der Energiemodus begrenzt sie (Ausgewogen halbiert, Stromsparend = 1). KI- und Bildanfragen laufen unabhängig davon parallel.") {
                let mode = PowerMonitor.shared.mode(for: store.settings)
                ForEach(TTSEngineID.allCases.filter { $0.maxWorkers > 1 }) { engine in
                    PillRow(title: engine.shortName, subtitle: String(format: L("wirksam: %d (%@)"), mode.ttsWorkers(userSetting: store.settings.ttsWorkers(for: engine)), mode.displayName)) {
                        PillStepper(value: Binding(
                            get: { store.settings.ttsWorkers(for: engine) },
                            set: { store.settings.ttsWorkersByEngine[engine.rawValue] = $0 }
                        ), range: 1...engine.maxWorkers)
                    }
                }
                PillRow(title: "KI-Anfragen", subtitle: store.settings.llmProvider == .omlx
                        ? L("Zusammenfassung und Gliederung (oMLX bündelt parallele Anfragen).")
                        : L("Zusammenfassung und Gliederung (LM Studio arbeitet sie nacheinander ab).")) {
                    PillStepper(value: Binding(
                        get: { store.settings.llmProvider == .omlx ? store.settings.omlxParallelRequests : store.settings.lmStudioParallelRequests },
                        set: { if store.settings.llmProvider == .omlx { store.settings.omlxParallelRequests = $0 } else { store.settings.lmStudioParallelRequests = $0 } }
                    ), range: 1...8)
                }
                PillRow(title: "Bildbeschreibungen", subtitle: "Gleichzeitige Anfragen an das Vision-Modell.") {
                    PillStepper(value: $store.settings.visionParallelRequests, range: 1...8)
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
        }
    }
}

// MARK: - Engines

private struct EnginesSettingsPane: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Installiert", footer: "Jede Engine mit Version und belegtem Platz; aufgeklappt jeder Bestandteil zum Laden oder Entfernen. Stimmen hörst du am besten in der Stimmen-Galerie an und installierst sie dort. Phonon auf der Neural Engine: Im Energiemodus „Stromsparend“ spricht Phonon über die Neural Engine — kaum langsamer, viel sparsamer; je Sprache einmal vorbereiten (~200 MB).") {
                EngineInventoryList()
            }

            PillSection("Hugging Face", footer: "Phonon und Pocket TTS sind geschützte Modelle: einmal anmelden und je Modell den Nutzungsbedingungen zustimmen.") {
                HuggingFaceAccountCard()
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

extension TTSEngineID {
    /// Short engine names for pickers (the long names explain the runtime).
    var shortName: String {
        switch self {
        case .kokoro: return L("Kokoro")
        case .piper: return L("Piper")
        case .kokoroGerman: return L("Kokoro Deutsch")
        case .kokoroThorsten: return L("Kokoro Thorsten")
        case .supertonic3: return L("Supertonic 3")
        case .omniVoice: return L("OmniVoice")
        case .appleSystem: return L("macOS-Systemstimmen")
        case .phonon: return L("Phonon")
        case .pocketTTS: return L("Pocket TTS")
        }
    }
}

// MARK: - Appearance

/// Erscheinungsbild (plan 9.2) — mirrors the template one to one.
struct AppearanceSettingsSection: View {
    @Environment(FunCenter.self) private var fun: FunCenter?
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

            PillSection("Spaß & Easter Eggs", footer: "Kleine Extras mit Anspielungen auf Spiele, Filme und Bücher — alles eigene Sounds und Pixelbilder. Der Pixel-Modus will gut überlegt sein; der Konami-Code führt übrigens auch dorthin.") {
                PillRow(title: "Soundeffekte", subtitle: "Kurze 8-Bit-Töne: fertiges Hörbuch, Eulenpost, Erfolge, Streicheln.") {
                    PillToggle(isOn: $store.settings.soundEffectsEnabled)
                }
                PillRow(title: "Eulenpost", subtitle: "Eine Eule bringt die Nachricht, wenn ein Hörbuch fertig ist.") {
                    PillToggle(isOn: $store.settings.owlPostEnabled)
                }
                PillRow(title: "Lade-Sprüche", subtitle: "Etwas zu lesen, während die Werkstatt arbeitet.") {
                    PillToggle(isOn: $store.settings.loadingQuipsEnabled)
                }
                PillRow(title: "Sehr langer Hund", subtitle: "Passt die Kapitelleiste nicht mehr ins Fenster, wird sie zum Hals eines Hundes.") {
                    PillToggle(isOn: $store.settings.lesserDogEnabled)
                }
                PillRow(title: "Pixel-Modus", subtitle: "Die ganze App im Look von 1998. Mit Sicherheitsabfrage. Mehreren.") {
                    PillToggle(isOn: Binding(
                        get: { store.settings.pixelMode },
                        set: { on in if on { fun?.requestPixelMode() } else { store.settings.pixelMode = false } }
                    ))
                }
                AchievementsGrid(unlocked: store.settings.unlockedAchievements, dogPets: store.settings.dogPets)
            }
        }
    }
}

/// System or one of the app languages (v4: + Français, Español,
/// Italiano), applied on relaunch (macOS loads the app's
/// language at start); the restart button relaunches immediately.
private struct LanguageRow: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var launchedWith = AppLanguage.current

    private var pendingRestart: Bool {
        let chosen = settingsStore.settings.appLanguage
        let effective = chosen == .system ? AppLanguage.resolvedSystemLanguage() : chosen.rawValue
        return effective != launchedWith
    }

    var body: some View {
        @Bindable var store = settingsStore
        PillRow(title: "App-Sprache", subtitle: pendingRestart ? "Wird nach dem Neustart übernommen." : "„System“ folgt der Sprache deines Macs.") {
            HStack(spacing: 10) {
                PillPicker(selection: $store.settings.appLanguage, options:
                    [PillOption(value: AppLanguage.system, label: "System", systemImage: "globe")]
                    + AppLanguage.concrete.map { PillOption(value: $0, label: $0.displayName, verbatim: true) })
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
                .appFont(size: 17, weight: .semibold)
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

/// Unlocked and still hidden achievements (v4.3).
private struct AchievementsGrid: View {
    let unlocked: [String: Date]
    let dogPets: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Erfolge").flowFont(.body, weight: .semibold)
                Spacer()
                Text(String(format: L("%d von %d"), unlocked.count, Achievement.allCases.count))
                    .flowFont(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(Achievement.allCases) { achievement in
                    let done = unlocked[achievement.rawValue] != nil
                    HStack(spacing: 10) {
                        Image(systemName: done ? achievement.systemImage : "lock.fill")
                            .frame(width: 24)
                            .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: done ? achievement.title : "???").flowFont(.callout, weight: .semibold)
                            Text(verbatim: done ? achievement.detail : L("Noch nicht freigeschaltet"))
                                .flowFont(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(done ? 0.05 : 0.025)))
                }
            }
            if dogPets > 0 {
                Text(String(format: L("Den Hund %d-mal gestreichelt."), dogPets))
                    .flowFont(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }
}
