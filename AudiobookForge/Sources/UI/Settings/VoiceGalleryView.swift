import SwiftUI
import UniformTypeIdentifiers

/// Voice gallery (plan 8.2): all known voices grouped by language, with
/// quality, tags and instant previews. The engine is deliberately not part
/// of the user-visible names (tooltip only).
///
/// Two modes:
/// - Defaults mode (Settings → „Stimmen"): selecting a voice sets the
///   language's default (`defaultVoiceDE` / `defaultVoiceEN`).
/// - Book mode (Review): `onSelect` receives the chosen voice, the caller
///   applies it to the book ("Für dieses Buch verwenden").
struct VoiceGalleryView: View {
    var onSelect: ((VoiceID) -> Void)?
    /// The book's current voice (book mode) — marked with a checkmark.
    var currentVoice: VoiceID?

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = VoicePreviewPlayer()

    private enum GenderFilter: String, CaseIterable, Identifiable {
        case all = "Alle"
        case female = "Weiblich"
        case male = "Männlich"
        var id: String { rawValue }
    }

    @State private var genderFilter: GenderFilter = .all
    @State private var onlyAvailable = false
    @State private var pendingDownloadVoice: String?
    @State private var voiceToDownload: VoiceProfile?
    @State private var downloadingVoice: String?
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?
    @State private var clones: [VoiceClone] = []
    @State private var showingCloneRecorder = false
    @State private var pendingImportURL: URL?
    @State private var showingCloneImporter = false
    @State private var clonePendingDeletion: VoiceClone?
    /// Verfügbarkeits-Cache: Modell-/Umgebungsprüfungen sind Festplatten-
    /// zugriffe (teils Verzeichnis-Scans über den HF-Cache) und laufen
    /// deshalb NICHT im View-Body, sondern einmalig im Hintergrund.
    @State private var availability: [VoiceID: Bool] = [:]
    @State private var cloneEngineAvailability: [TTSEngineID: Bool] = [:]
    @State private var availabilityRefreshToken = 0

    private var settings: AppSettings { settingsStore.settings }

    private var isBookMode: Bool { onSelect != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isBookMode ? "Sprecher:in für dieses Buch" : "Sprecherkartei")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                    Text("Hörprobe antippen · Karte wählen")
                        .flowFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SegmentedPills(selection: $genderFilter, options: GenderFilter.allCases.map { PillOption(value: $0, label: $0.rawValue) }, size: .small)
                SegmentedPills(selection: $onlyAvailable, options: [
                    PillOption(value: false, label: "Alle"),
                    PillOption(value: true, label: "Eingerichtet"),
                ], size: .small)
                Button("Fertig") { dismiss() }
                    .buttonStyle(.flowProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

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
                    cloneSection
                    ForEach(VoiceCatalog.languageGroups, id: \.self) { group in
                        let featured = filtered(VoiceCatalog.profiles(languageGroup: group).filter(\.featured))
                        let more = filtered(VoiceCatalog.profiles(languageGroup: group).filter { !$0.featured })
                        if !featured.isEmpty || !more.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L(group))
                                    .flowFont(.caption, weight: .semibold)
                                    .foregroundStyle(.tint)
                                    .textCase(.uppercase)
                                    .tracking(1.1)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                                    ForEach(featured) { profile in voiceRow(profile) }
                                }
                                if !more.isEmpty {
                                    DisclosureGroup("Weitere Stimmen (\(more.count))") {
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                                            ForEach(more) { profile in voiceRow(profile) }
                                        }
                                        .padding(.top, 8)
                                    }
                                    .flowFont(.callout, weight: .medium)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 600, idealHeight: 720)
        .background { PaperPage() }
        .navigationTitle(isBookMode ? "Stimme für dieses Buch" : "Stimmen")
        .onAppear { clones = VoiceCloneStore.shared.clones() }
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
        .alert("Stimme herunterladen?", isPresented: Binding(get: { voiceToDownload != nil }, set: { if !$0 { voiceToDownload = nil } })) {
            Button("Herunterladen", role: .none) {
                if let profile = voiceToDownload {
                    startPiperDownload(profile)
                }
                voiceToDownload = nil
            }
            Button("Abbrechen", role: .cancel) { voiceToDownload = nil }
        } message: {
            if let profile = voiceToDownload {
                Text("„\(profile.displayName)“ wird von Hugging Face (rhasspy/piper-voices, MIT-Lizenz) geladen und in der Piper-Umgebung der App abgelegt.")
            }
        }
    }

    /// Eigene Stimmen (Stimmklon): Referenzaufnahmen, die von der
    /// bevorzugten Klon-Engine nachgeahmt werden. Nur sichtbar, wenn eine
    /// klon-fähige Engine installiert ist.
    private var cloneSection: some View {
        let cloneEngine = settings.preferredCloneEngine
        let engineAvailable = cloneEngineAvailability[cloneEngine] ?? false
        return Group {
            HStack {
                Text("Eigene Stimmen")
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                    .tracking(1.1)
                Spacer()
                Button { showingCloneRecorder = true } label: { Label("Aufnehmen", systemImage: "mic.fill") }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                Button { showingCloneImporter = true } label: { Label("Datei", systemImage: "waveform.badge.plus") }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            }
            .padding(.top, 4)

            Text("Aufnahme oder Audiodatei wird als eigene Stimme angelegt und von \(cloneEngine.displayName) nachgeahmt\(engineAvailable ? "" : " — Engine noch nicht eingerichtet (Einstellungen → Diagnose)").")
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
                Text(clone.languageCode == "de" ? "Eigene Stimme · Deutsch" : "Eigene Stimme · Englisch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                    if !isBookMode {
                        Text(clone.languageCode.hasPrefix("de") ? "Standard (DE)" : "Standard (EN)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            } else if isBookMode {
                Button("Verwenden") {
                    onSelect?(voiceID)
                    dismiss()
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
                onSelect?(voiceID)
                dismiss()
            } else {
                applyCloneDefault(clone, engine: engine)
            }
        }
        .help("Eigene Stimme — gerendert mit \(engine.displayName)")
    }

    /// Background probe of a clone engine's readiness (file checks only).
    nonisolated private static func isCloneEngineReady(_ engine: TTSEngineID) -> Bool {
        switch engine {
        case .omniVoice: return OmniVoiceEnvironmentManager.shared.isReady()
        default: return false
        }
    }

    private func isSelected(voiceID: VoiceID, languageCode: String) -> Bool {
        if isBookMode, let currentVoice { return currentVoice == voiceID }
        if languageCode.hasPrefix("de") { return settings.defaultVoiceDE == voiceID }
        return settings.defaultVoiceEN == voiceID
    }

    private func applyCloneDefault(_ clone: VoiceClone, engine: TTSEngineID) {
        let voiceID = VoiceCloneStore.voiceID(for: clone, engine: engine)
        settingsStore.settings.ttsEngine = engine
        if clone.languageCode.hasPrefix("de") {
            settingsStore.settings.defaultVoiceDE = voiceID
        } else {
            settingsStore.settings.defaultVoiceEN = voiceID
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
        let result = await Task.detached(priority: .userInitiated) { () -> ([VoiceID: Bool], [TTSEngineID: Bool]) in
            var availability: [VoiceID: Bool] = [:]
            for profile in profiles {
                availability[profile.id] = Self.probeAvailability(profile)
            }
            var cloneEngines: [TTSEngineID: Bool] = [:]
            cloneEngines[.omniVoice] = Self.isCloneEngineReady(.omniVoice)
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
        let needsDownload = profile.id.engine == .piper && !available
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if needsDownload {
                    if downloadingVoice == profile.id.voice {
                        ProgressRing(fraction: max(downloadProgress, 0.03), lineWidth: 3)
                            .frame(width: 26, height: 26)
                    } else {
                        Button { downloadPiperVoice(profile) } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(downloadingVoice != nil)
                        .help("Stimme laden (~60 MB, Hugging Face rhasspy/piper-voices) — nach Bestätigung")
                    }
                } else {
                    Button {
                        preview.toggle(text: profile.sampleText, engineID: profile.id.engine, voice: profile.id.voice, speed: settings.defaultSpeed(for: profile.id.engine), settings: settings)
                    } label: {
                        Image(systemName: busyWithThisVoice && preview.isPlaying ? "stop.fill" : (busyWithThisVoice && preview.isGenerating ? "waveform" : "play.fill"))
                            .font(.system(size: 14, weight: .bold))
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: busyWithThisVoice && preview.isGenerating)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .help(available ? "Hörprobe" : "Noch nicht eingerichtet (Einstellungen → Engines & Leistung)")
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
                Text("\(profile.gender.label) · \(profile.languageCode)\(available || needsDownload ? "" : " · nicht eingerichtet")\(needsDownload ? " · zum Laden" : "")")
                    .flowFont(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    StatusBadge(text: profile.speed.label, systemImage: "hare")
                    ForEach(profile.tags.prefix(2), id: \.self) { tag in
                        StatusBadge(text: tag, tint: .secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if selected {
                VStack(spacing: 2) {
                    RibbonShape()
                        .fill(.tint)
                        .frame(width: 14, height: 30)
                    if !isBookMode {
                        Text(profile.languageGroup == "Deutsch" ? "DE" : (profile.languageGroup == "Englisch" ? "EN" : "★"))
                            .flowFont(.caption2, weight: .bold)
                            .foregroundStyle(.tint)
                    }
                }
                .offset(y: -14)
                .help(isBookMode ? "Aktuelle Stimme dieses Buches" : "Standardstimme für \(profile.languageGroup)")
            }
        }
        .padding(14)
        .flowSurface(cornerRadius: Theme.Radius.row)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isBookMode {
                onSelect?(profile.id)
                dismiss()
            } else {
                applyDefault(profile)
            }
        }
        .opacity(available || needsDownload ? 1 : 0.6)
        .help("\(profile.id.engine.shortName) · „\(profile.id.voice)“ — Karte antippen \(isBookMode ? "verwendet sie für dieses Buch" : "macht sie zur Standardstimme")")
    }

    private func downloadPiperVoice(_ profile: VoiceProfile) {
        voiceToDownload = profile
    }

    private func startPiperDownload(_ profile: VoiceProfile) {
        pendingDownloadVoice = nil
        guard let voice = PiperVoiceCatalog.voice(id: profile.id.voice) else { return }
        downloadingVoice = profile.id.voice
        downloadProgress = 0
        let manager = PiperEnvironmentManager.shared
        Task<Void, Never> {
            do {
                try await manager.downloadVoice(voice) { fraction in
                    Task { @MainActor in
                        downloadProgress = fraction
                    }
                }
                await MainActor.run {
                    downloadingVoice = nil
                    availabilityRefreshToken += 1
                }
            } catch {
                await MainActor.run {
                    downloadingVoice = nil
                    downloadError = error.localizedDescription
                }
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
        if isBookMode, let currentVoice {
            return currentVoice == profile.id
        }
        if profile.languageGroup == "Deutsch" {
            return settings.defaultVoiceDE == profile.id
        }
        if profile.languageGroup == "Englisch" {
            return settings.defaultVoiceEN == profile.id
        }
        return false
    }

    private func applyDefault(_ profile: VoiceProfile) {
        if isBookMode {
            onSelect?(profile.id)
            dismiss()
            return
        }
        settingsStore.settings.ttsEngine = profile.id.engine
        switch profile.languageGroup {
        case "Deutsch":
            settingsStore.settings.defaultVoiceDE = profile.id
        case "Englisch":
            settingsStore.settings.defaultVoiceEN = profile.id
        default:
            break
        }
    }

    /// Cached availability — filled by `refreshAvailability()`; false until
    /// the background probe finishes.
    private func isAvailable(_ profile: VoiceProfile) -> Bool {
        availability[profile.id] ?? false
    }

    /// Synchronous probe (file/env checks) — background use only, never in
    /// a view body.
    nonisolated private static func probeAvailability(_ profile: VoiceProfile) -> Bool {
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
        }
    }
}
