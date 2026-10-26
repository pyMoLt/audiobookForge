import SwiftUI
import UniformTypeIdentifiers

/// Voice gallery (plan 8.2, redesigned v4): a curated list per language
/// ("Beste Qualität" / "Am schnellsten") and "Alle Stimmen" with filters for
/// engine, gender and installed voices; picking an engine shows what it
/// can. Five languages (DE/EN/FR/ES/IT); previews play instantly.
///
/// Two modes:
/// - Defaults mode (Settings → „Stimmen"): selecting a voice sets the
///   language's default voice.
/// - Book mode (Review, Neu vertonen): `onSelect` receives the chosen voice.
struct VoiceGalleryView: View {
    var onSelect: ((VoiceID) -> Void)?
    /// The book's current voice (book mode) — marked with a ribbon.
    var currentVoice: VoiceID?
    /// Language shown first (book language); nil = German.
    var languageCode: String? = nil
    /// Sentence from the book for previews (book mode, same language).
    var previewText: String? = nil
    /// Book mode: close the sheet after picking (false when embedded).
    var dismissOnSelect: Bool = true
    var embedded: Bool = false

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = VoicePreviewPlayer()

    private enum GenderFilter: String, CaseIterable, Identifiable {
        case all = "Alle"
        case female = "Weiblich"
        case male = "Männlich"
        var id: String { rawValue }
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case recommended, all
        var id: String { rawValue }
        var label: String { self == .recommended ? L("Empfohlen") : L("Alle Stimmen") }
    }

    @State private var language = "de"
    @State private var tab: Tab = .recommended
    @State private var engineFilter: TTSEngineID?
    @State private var genderFilter: GenderFilter = .all
    @State private var onlyAvailable = false
    /// Voice whose missing pieces the install sheet offers (v4.2).
    @State private var installingProfile: VoiceProfile?
    /// Set when the card itself was tapped: choose the voice once installed.
    @State private var chooseAfterInstall: VoiceID?
    @State private var voicePendingRemoval: (profile: VoiceProfile, component: EngineComponent)?
    @State private var downloadError: String?
    @State private var clones: [VoiceClone] = []
    @State private var showingCloneRecorder = false
    @State private var pendingImportURL: URL?
    @State private var showingCloneImporter = false
    @State private var clonePendingDeletion: VoiceClone?
    /// Verfügbarkeits-Cache: Modell-/Umgebungsprüfungen sind Festplatten-
    /// zugriffe und laufen deshalb NICHT im View-Body, sondern einmalig im
    /// Hintergrund.
    @State private var availability: [VoiceID: Bool] = [:]
    @State private var cloneEngineAvailability: [TTSEngineID: Bool] = [:]
    @State private var availabilityRefreshToken = 0

    private var settings: AppSettings { settingsStore.settings }

    private var isBookMode: Bool { onSelect != nil }

    private static let columns = [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = preview.errorMessage ?? downloadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .flowFont(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == .recommended {
                        cloneSection
                        ForEach(VoiceCatalog.Curation.allCases) { curation in
                            let voices = VoiceCatalog.curated(curation, language: language)
                            if !voices.isEmpty {
                                sectionTitle(curation.title)
                                LazyVGrid(columns: Self.columns, spacing: 12) {
                                    ForEach(voices) { profile in voiceRow(profile) }
                                }
                            }
                        }
                        Button {
                            tab = .all
                        } label: {
                            Label(String(format: L("Alle %d Stimmen auf %@ ansehen"), VoiceCatalog.profiles(language: language).count, languageDisplayName(language)), systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                    } else {
                        if let engineFilter { engineCard(engineFilter) }
                        let voices = allVoices
                        if voices.isEmpty {
                            Text("Keine Stimme passt zu den Filtern.")
                                .flowFont(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        LazyVGrid(columns: Self.columns, spacing: 12) {
                            ForEach(voices) { profile in voiceRow(profile) }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .modifier(GallerySheetFrame(embedded: embedded))
        .background { if !embedded { PaperPage() } }
        .navigationTitle(isBookMode ? "Stimme für dieses Buch" : "Stimmen")
        .onAppear {
            clones = VoiceCloneStore.shared.clones()
            let initial = String((languageCode ?? "de").prefix(2))
            language = VoiceCatalog.galleryLanguages.contains(initial) ? initial : "de"
        }
        .onChange(of: language) { _, _ in
            if let engineFilter, !VoiceCatalog.engines(language: language).contains(engineFilter) { self.engineFilter = nil }
        }
        .task(id: availabilityRefreshToken) {
            await refreshAvailability()
        }
        .onDisappear {
            preview.stop()
        }
        .sheet(isPresented: $showingCloneRecorder) {
            VoiceCloneEditorView(mode: .record) { _ in clones = VoiceCloneStore.shared.clones() }
        }
        .sheet(isPresented: Binding(get: { pendingImportURL != nil }, set: { if !$0 { pendingImportURL = nil } })) {
            if let url = pendingImportURL {
                VoiceCloneEditorView(mode: .importedFile(url)) { _ in clones = VoiceCloneStore.shared.clones() }
            }
        }
        .fileImporter(isPresented: $showingCloneImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                pendingImportURL = url
            }
        }
        .confirmationDialog("Eigene Stimme löschen?", isPresented: Binding(get: { clonePendingDeletion != nil }, set: { if !$0 { clonePendingDeletion = nil } })) {
            Button("Löschen", role: .destructive) {
                if let clone = clonePendingDeletion {
                    VoiceCloneStore.shared.delete(id: clone.id)
                    clones = VoiceCloneStore.shared.clones()
                }
                clonePendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) { clonePendingDeletion = nil }
        } message: {
            if let clone = clonePendingDeletion {
                Text("„\(clone.name)“ wird entfernt. Bücher, die sie nutzen, fallen auf ihre Standardstimme zurück.")
            }
        }
        .sheet(item: $installingProfile, onDismiss: { chooseAfterInstall = nil }) { profile in
            VoiceInstallSheet(profile: profile) {
                availabilityRefreshToken += 1
                if chooseAfterInstall == profile.id {
                    chooseAfterInstall = nil
                    applyDefault(profile)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .engineInventoryChanged)) { _ in availabilityRefreshToken += 1 }
        #if DEBUG
        // Visual pass (v4.2.2): galleryTab=all|recommended, galleryLanguage=it,
        // galleryEngine=pocketTTS|none, galleryInstall=<engine>:<voice>
        .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            if let value = info["galleryTab"] { tab = value == "all" ? .all : .recommended }
            if info["galleryRecord"] == "open" { showingCloneRecorder = true }
            if let value = info["galleryLanguage"] { language = value }
            if let value = info["galleryEngine"] { engineFilter = TTSEngineID(rawValue: value) }
            if let spec = info["galleryInstall"], let colon = spec.firstIndex(of: ":"),
               let engine = TTSEngineID(rawValue: String(spec[..<colon])),
               let profile = VoiceCatalog.profile(for: VoiceID(engine: engine, voice: String(spec[spec.index(after: colon)...]))) {
                installingProfile = profile
            }
        }
        #endif
        .confirmationDialog(String(format: L("„%@“ entfernen?"), voicePendingRemoval?.profile.displayName ?? ""),
                            isPresented: Binding(get: { voicePendingRemoval != nil }, set: { if !$0 { voicePendingRemoval = nil } })) {
            if let pending = voicePendingRemoval {
                Button(String(format: L("%@ freigeben"), pending.component.sizeText), role: .destructive) {
                    Task {
                        do { try await ComponentRunner.remove(pending.component) } catch { downloadError = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text("Die Hörprobe bleibt; zum Vorlesen lädst du die Stimme hier wieder.")
        }
    }

    // MARK: - Header & filters

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isBookMode ? "Sprecher:in für dieses Buch" : "Sprecherkartei")
                        .appFont(size: 22, weight: .semibold, design: .serif)
                    Text("Hörprobe antippen · Karte wählen")
                        .flowFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !embedded {
                    Button("Fertig") { dismiss() }
                        .buttonStyle(.flowProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { languagePills; Spacer(minLength: 8); tabPills }
                VStack(alignment: .leading, spacing: 8) { languagePills; tabPills }
            }
            if tab == .all {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { enginePicker; genderPills; availabilityPills; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 8) { enginePicker; HStack(spacing: 10) { genderPills; availabilityPills } }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var languagePills: some View {
        SegmentedPills(selection: $language, options: VoiceCatalog.galleryLanguages.map {
            PillOption(value: $0, label: languageDisplayName($0), shortLabel: $0.uppercased(), verbatim: true)
        }, size: .small)
    }

    private var tabPills: some View {
        SegmentedPills(selection: $tab, options: Tab.allCases.map { PillOption(value: $0, label: $0.label, verbatim: true) }, size: .small)
    }

    private var enginePicker: some View {
        PillPicker(selection: $engineFilter, options:
            [PillOption(value: TTSEngineID?.none, label: L("Alle Engines"), verbatim: true)]
            + VoiceCatalog.engines(language: language).map { PillOption(value: TTSEngineID?.some($0), label: $0.shortName, verbatim: true) })
    }

    private var genderPills: some View {
        SegmentedPills(selection: $genderFilter, options: GenderFilter.allCases.map { PillOption(value: $0, label: $0.rawValue) }, size: .small)
    }

    private var availabilityPills: some View {
        SegmentedPills(selection: $onlyAvailable, options: [
            PillOption(value: false, label: "Alle"),
            PillOption(value: true, label: "Eingerichtet"),
        ], size: .small)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .flowFont(.caption, weight: .semibold)
            .foregroundStyle(.tint)
            .textCase(.uppercase)
            .tracking(1.1)
            .padding(.top, 4)
    }

    /// Every voice of the language that passes the filters: recommended
    /// first, then by quality and speed.
    private var allVoices: [VoiceProfile] {
        filtered(VoiceCatalog.profiles(language: language))
            .filter { engineFilter == nil || $0.id.engine == engineFilter }
            .sorted {
                ($0.featured ? 0 : 1, -$0.quality.points, $0.id.engine.speedRank, $0.displayName)
                    < ($1.featured ? 0 : 1, -$1.quality.points, $1.id.engine.speedRank, $1.displayName)
            }
    }

    /// What one engine can: portrait, languages, speed, cloning, setup.
    private func engineCard(_ engine: TTSEngineID) -> some View {
        let installed = VoiceCatalog.profiles(language: language).contains { $0.id.engine == engine && isAvailable($0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: engine.shortName).flowFont(.headline)
                Spacer()
                StatusBadge(text: installed ? L("Eingerichtet") : L("Nicht eingerichtet"),
                            systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                            tint: installed ? .green : .secondary)
            }
            Text(verbatim: engine.portrait).flowFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                StatusBadge(text: engine.languageCodes.map { $0.uppercased() }.joined(separator: " · "), systemImage: "globe")
                StatusBadge(text: [L("Sehr schnell"), L("Sehr schnell"), L("Schnell"), L("Schnell"), L("Echtzeit"), L("Langsam")][min(engine.speedRank, 5)], systemImage: "hare")
                if engine.supportsCloning { StatusBadge(text: L("Klonen"), systemImage: "person.2.wave.2") }
            }
            Label(engine.license, systemImage: "doc.text")
                .flowFont(.caption)
                .foregroundStyle(.secondary)
            if !installed {
                if let first = VoiceCatalog.profiles(language: language).first(where: { $0.id.engine == engine }) {
                    Button { installingProfile = first } label: {
                        Label(String(format: L("%@ installieren"), engine.shortName), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }

    private func sample(for profile: VoiceProfile) -> String {
        if let previewText, profile.baseLanguage == language { return previewText }
        return profile.sampleText
    }

    /// Eigene Stimmen (Stimmklon): Referenzaufnahmen, die von der
    /// bevorzugten Klon-Engine nachgeahmt werden. Nur sichtbar, wenn eine
    /// klon-fähige Engine installiert ist.
    private var cloneTitle: some View {
        Text("Eigene Stimmen")
            .flowFont(.caption, weight: .semibold)
            .foregroundStyle(.tint)
            .textCase(.uppercase)
            .tracking(1.1)
            .fixedSize()
    }

    private var cloneEnginePills: some View {
        SegmentedPills(selection: Binding(get: { settingsStore.settings.preferredCloneEngine },
                                          set: { settingsStore.settings.preferredCloneEngine = $0 }),
                       options: [PillOption(value: TTSEngineID.pocketTTS, label: L("Pocket TTS (schnell)"), verbatim: true),
                                 PillOption(value: TTSEngineID.omniVoice, label: L("OmniVoice (600+ Sprachen)"), verbatim: true)],
                       size: .small)
            .fixedSize()
    }

    @ViewBuilder private var cloneButtons: some View {
        Button { showingCloneRecorder = true } label: { Label("Aufnehmen", systemImage: "mic.fill") }
            .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            .fixedSize()
        Button { showingCloneImporter = true } label: { Label("Datei", systemImage: "waveform.badge.plus") }
            .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            .fixedSize()
    }

    private var cloneSection: some View {
        let cloneEngine = settings.preferredCloneEngine
        let engineAvailable = cloneEngineAvailability[cloneEngine] ?? false
        return Group {
            // Narrow sheets (v4.1): the controls move below the title
            // instead of squeezing it letter by letter.
            ViewThatFits(in: .horizontal) {
                HStack {
                    cloneTitle
                    Spacer()
                    cloneEnginePills
                    cloneButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    cloneTitle
                    HStack { cloneEnginePills; cloneButtons }
                }
                VStack(alignment: .leading, spacing: 8) {
                    cloneTitle
                    cloneEnginePills
                    HStack { cloneButtons }
                }
            }
            .padding(.top, 4)

            Text(String(format: L("Aufnahme oder Audiodatei wird als eigene Stimme angelegt und von %@ nachgeahmt."), cloneEngine.shortName)
                 + (engineAvailable ? "" : " " + L("Engine noch nicht eingerichtet (Einstellungen → Engines & Downloads).")))
                .flowFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(clones) { clone in
                cloneRow(clone, engine: cloneEngine, engineAvailable: engineAvailable)
            }
            if clones.isEmpty {
                Text("Noch keine eigene Stimme angelegt — „Aufnehmen“ spricht 10–20 s, oder eine Audiodatei importieren.")
                    .flowFont(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
        }
    }

    @ViewBuilder
    private func cloneRow(_ clone: VoiceClone, engine: TTSEngineID, engineAvailable: Bool) -> some View {
        let voiceID = VoiceCloneStore.voiceID(for: clone, engine: engine)
        let selected = isSelected(voiceID: voiceID, languageCode: clone.languageCode)
        HStack(spacing: 12) {
            Button {
                preview.toggle(text: clone.refText.isEmpty ? VoiceCatalog.germanSampleText : clone.refText, engineID: engine, voice: voiceID.voice, speed: 1.0, settings: settings)
            } label: {
                Image(systemName: preview.currentVoiceID == voiceID && (preview.isPlaying || preview.isGenerating) ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!engineAvailable)

            VStack(alignment: .leading, spacing: 2) {
                Text(clone.name)
                    .font(.body.weight(.medium))
                Text(L("Eigene Stimme") + " · " + languageDisplayName(String(clone.languageCode.prefix(2))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                    if !isBookMode {
                        Text(verbatim: "Standard (\(clone.languageCode.prefix(2).uppercased()))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            } else if isBookMode {
                Button("Verwenden") {
                    choose(voiceID)
                }
                .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            }
            Menu {
                Button("Löschen …", role: .destructive) { clonePendingDeletion = clone }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(14)
        .flowSurface(cornerRadius: Theme.Radius.row)
        .contentShape(Rectangle())
        .onTapGesture {
            if isBookMode {
                choose(voiceID)
            } else {
                applyCloneDefault(clone, engine: engine)
            }
        }
        .help(L("Eigene Stimme — gerendert mit") + " " + engine.shortName)
    }

    /// Background probe of a clone engine's readiness (file checks only).
    nonisolated private static func isCloneEngineReady(_ engine: TTSEngineID) -> Bool {
        switch engine {
        case .omniVoice: return OmniVoiceEnvironmentManager.shared.isReady()
        case .pocketTTS: return PocketEnvironmentManager.shared.isEnvironmentReady() && !PocketEnvironmentManager.shared.installedLanguages.isEmpty
        default: return false
        }
    }

    private func isSelected(voiceID: VoiceID, languageCode: String) -> Bool {
        if isBookMode, let currentVoice { return currentVoice == voiceID }
        return settings.defaultVoiceID(forLanguage: String(languageCode.prefix(2))) == voiceID
    }

    private func applyCloneDefault(_ clone: VoiceClone, engine: TTSEngineID) {
        setDefault(VoiceCloneStore.voiceID(for: clone, engine: engine), language: String(clone.languageCode.prefix(2)))
    }

    /// Book mode: hand the voice to the caller (and close, unless embedded).
    private func choose(_ voiceID: VoiceID) {
        onSelect?(voiceID)
        if dismissOnSelect && !embedded { dismiss() }
    }

    /// Defaults mode: the language's default voice.
    private func setDefault(_ voiceID: VoiceID, language: String) {
        // The fallback for other languages has its own row (v4.2): choosing
        // a language default no longer changes it behind the user's back.
        switch language {
        case "de": settingsStore.settings.defaultVoiceDE = voiceID
        case "en": settingsStore.settings.defaultVoiceEN = voiceID
        default: settingsStore.settings.defaultVoicesByLanguage[language] = voiceID
        }
    }

    private func filtered(_ profiles: [VoiceProfile]) -> [VoiceProfile] {
        profiles.filter { profile in
            (genderFilter == .all || profile.gender.rawValue == genderFilter.rawValue.lowercased())
            && (!onlyAvailable || isAvailable(profile))
        }
    }

    /// Prüft alle Stimmen und Klon-Engines einmalig im Hintergrund und
    /// füllt die Caches. Body-Lesezugriffe bleiben reine Dict-Lookups.
    private func refreshAvailability() async {
        let profiles = VoiceCatalog.allProfiles
        let settings = settingsStore.settings
        let result = await Task.detached(priority: .userInitiated) { () -> ([VoiceID: Bool], [TTSEngineID: Bool]) in
            var availability: [VoiceID: Bool] = [:]
            for profile in profiles {
                availability[profile.id] = Self.probeAvailability(profile, settings: settings)
            }
            var cloneEngines: [TTSEngineID: Bool] = [:]
            cloneEngines[.omniVoice] = Self.isCloneEngineReady(.omniVoice)
            cloneEngines[.pocketTTS] = Self.isCloneEngineReady(.pocketTTS)
            return (availability, cloneEngines)
        }.value
        availability = result.0
        cloneEngineAvailability = result.1
    }

    /// A voice as a card in the speaker catalogue.
    @ViewBuilder
    private func voiceRow(_ profile: VoiceProfile) -> some View {
        let selected = isSelected(profile)
        let available = isAvailable(profile)
        let busyWithThisVoice = preview.currentVoiceID == profile.id
        let needsDownload = !available && profile.id.engine != .appleSystem
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if needsDownload && !VoiceSampleLibrary.has(profile.id) {
                    Button { installingProfile = profile } label: {
                        Image(systemName: "arrow.down")
                            .appFont(size: 14, weight: .bold)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stimme installieren — zeigt vorher, was geladen wird")
                } else {
                    Button {
                        preview.toggle(text: sample(for: profile), engineID: profile.id.engine, voice: profile.id.voice, speed: settings.defaultSpeed(for: profile.id.engine), settings: settings)
                    } label: {
                        Image(systemName: busyWithThisVoice && preview.isPlaying ? "stop.fill" : (busyWithThisVoice && preview.isGenerating ? "waveform" : "play.fill"))
                            .appFont(size: 14, weight: .bold)
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: busyWithThisVoice && preview.isGenerating)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!available && !(VoiceSampleLibrary.has(profile.id) && sample(for: profile) == profile.sampleText))
                    .help(available ? L("Hörprobe") : (VoiceSampleLibrary.has(profile.id) ? L("Mitgelieferte Hörprobe") : L("Noch nicht installiert")))
                }
            }
            .frame(width: 40, height: 40)
            .glassEffect(.regular.interactive(), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .flowFont(.headline)
                        .lineLimit(1)
                    Text(String(repeating: "★", count: profile.quality.points) + String(repeating: "☆", count: max(0, 3 - profile.quality.points)))
                        .flowFont(.caption)
                        .foregroundStyle(.orange)
                        .help(profile.quality.label)
                }
                Text(verbatim: "\(profile.gender.label) · \(profile.languageCode) · \(profile.id.engine.shortName)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .flowFont(.caption)
                    .foregroundStyle(.secondary)
                let badges = HStack(spacing: 5) {
                    StatusBadge(text: profile.speed.label, systemImage: "hare")
                    ForEach(profile.tags.prefix(1), id: \.self) { tag in
                        StatusBadge(text: tag, tint: .secondary)
                    }
                }
                if needsDownload {
                    // Heard the sample and like it: install right here. A
                    // fixed-size pill; on narrow cards it moves below the badges.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) { badges; installPill(profile) }
                        VStack(alignment: .leading, spacing: 6) { badges; installPill(profile) }
                    }
                } else {
                    badges
                }
            }
            Spacer(minLength: 0)
            if selected {
                VStack(spacing: 2) {
                    RibbonShape()
                        .fill(.tint)
                        .frame(width: 14, height: 30)
                    if !isBookMode {
                        Text(verbatim: profile.baseLanguage.uppercased())
                            .flowFont(.caption2, weight: .bold)
                            .foregroundStyle(.tint)
                    }
                }
                .offset(y: -14)
                .help(isBookMode ? L("Aktuelle Stimme dieses Buches") : L("Standardstimme für") + " " + languageDisplayName(profile.baseLanguage))
            }
        }
        .padding(14)
        // Same height for every card of a row, content at the top (v4.2.2).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .flowSurface(cornerRadius: Theme.Radius.row)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Not installed yet: install first, then choose it (v4.2.2) —
            // a voice that cannot speak is never set silently.
            if needsDownload {
                chooseAfterInstall = profile.id
                installingProfile = profile
            } else if isBookMode {
                choose(profile.id)
            } else {
                applyDefault(profile)
            }
        }
        .contextMenu {
            if available {
                Button(role: .destructive) { askRemoval(profile) } label: { Label("Stimme entfernen …", systemImage: "trash") }
            }
        }
        .help(needsDownload ? L("Karte antippen installiert die Stimme und wählt sie danach")
              : (isBookMode ? L("Karte antippen verwendet sie für dieses Buch") : L("Karte antippen macht sie zur Standardstimme")))
    }

    private func installPill(_ profile: VoiceProfile) -> some View {
        Button { installingProfile = profile } label: {
            Label("Installieren", systemImage: "arrow.down.circle")
                .flowFont(.caption, weight: .semibold)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(.tint.opacity(0.14)))
                .foregroundStyle(.tint)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Stimme installieren — zeigt vorher, was geladen wird")
    }

    /// Removable voices: Piper voices and the German Kokoro models (the
    /// others come with a language model — removed under Engines & Downloads).
    private func askRemoval(_ profile: VoiceProfile) {
        let settings = settingsStore.settings
        Task {
            let component = await Task.detached(priority: .userInitiated) { () -> EngineComponent? in
                let ids = EngineInventory.requiredComponentIDs(for: profile.id, settings: settings)
                return EngineInventory.status(of: profile.id.engine, settings: settings).components
                    .first { ids.contains($0.id) && $0.kind == .voice && $0.installed }
            }.value
            if let component {
                voicePendingRemoval = (profile, component)
            } else {
                NotificationCenter.default.post(name: .openSettingsPane, object: SettingsPane.engines.rawValue)
                if !embedded { dismiss() }
            }
        }
    }

    private func qualityBadge(_ quality: VoiceQuality) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { point in
                Image(systemName: point < quality.points ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(point < quality.points ? .yellow : .secondary)
            }
        }
        .help(quality.label)
    }

    private func isSelected(_ profile: VoiceProfile) -> Bool {
        if isBookMode, let currentVoice { return currentVoice == profile.id }
        return settings.defaultVoiceID(forLanguage: profile.baseLanguage) == profile.id
    }

    private func applyDefault(_ profile: VoiceProfile) {
        if isBookMode {
            choose(profile.id)
            return
        }
        setDefault(profile.id, language: profile.baseLanguage)
    }

    /// Cached availability — filled by `refreshAvailability()`; false until
    /// the background probe finishes.
    private func isAvailable(_ profile: VoiceProfile) -> Bool {
        availability[profile.id] ?? false
    }

    /// Synchronous probe (file/env checks) — background use only, never in
    /// a view body.
    nonisolated private static func probeAvailability(_ profile: VoiceProfile, settings: AppSettings) -> Bool {
        switch profile.id.engine {
        case .kokoro:
            return BridgeEnvironmentManager.shared.isEnvironmentReady()
        case .kokoroGerman, .kokoroThorsten:
            return GermanKokoroEnvironmentManager.shared.isVoiceReady(profile.id.voice)
        case .piper:
            return PiperEnvironmentManager.shared.isEnvironmentReady()
                && PiperEnvironmentManager.shared.isVoiceDownloaded(profile.id.voice)
        case .supertonic3:
            return SupertonicEnvironmentManager.shared.isReady()
        case .omniVoice:
            return OmniVoiceEnvironmentManager.shared.isReady()
        case .appleSystem:
            return true
        case .phonon:
            let (language, _) = PhononEngine.split(profile.id.voice)
            return PhononEnvironmentManager.shared.isReady(language: PhononEnvironmentManager.modelKey(language: language, english31m: settings.phononEnglish31m))
        case .pocketTTS:
            let (language, _) = PhononEngine.split(profile.id.voice)
            return PocketEnvironmentManager.shared.isModelReady(language) && PocketEnvironmentManager.shared.isEnvironmentReady()
        }
    }
}

/// As a sheet the gallery opens at a size that fits the window and can be
/// resized (v4.2.2); embedded (re-voice sheet) it just fills its space.
private struct GallerySheetFrame: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.resizableSheet(preferred: CGSize(width: 880, height: 720), floor: CGSize(width: 520, height: 460))
        }
    }
}
