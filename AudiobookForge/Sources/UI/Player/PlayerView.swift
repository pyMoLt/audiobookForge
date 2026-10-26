import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The listening & reading screen (v3.1).
///
/// Three presets — **Hören** (big stage with cover), **Lesen** (text is the
/// main content, compact player bar) and **Lernen** (chapters + text) — are
/// just combinations of two independent toggles: the chapter list and the
/// read-along text can each be collapsed. Playback lives in the app-wide
/// `PlaybackSession`, so leaving this screen never stops the book.
struct PlayerView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    @Environment(PlaybackSession.self) private var playback
    let bookID: UUID

    @AppStorage("player.showChapters") private var showChapters = false
    @AppStorage("player.showText") private var showText = true
    @State private var diffChapter: Chapter?
    @State private var renameBookTitle = ""
    @State private var showRenameBook = false
    @FocusState private var isFocused: Bool

    private var book: BookProject? { libraryStore.book(id: bookID) }

    enum LayoutPreset: String, CaseIterable, Identifiable {
        case listen, read, study
        var id: String { rawValue }
        var label: String {
            switch self {
            case .listen: return L("Hören")
            case .read: return L("Lesen")
            case .study: return L("Lernen")
            }
        }
        var systemImage: String {
            switch self {
            case .listen: return "headphones"
            case .read: return "text.book.closed"
            case .study: return "rectangle.split.3x1"
            }
        }
        var panes: (chapters: Bool, text: Bool) {
            switch self {
            case .listen: return (false, false)
            case .read: return (false, true)
            case .study: return (true, true)
            }
        }
    }

    var body: some View {
        if let book {
            Group {
                if playback.bookID == bookID, let volume = playback.missingVolume {
                    missingSourceView(book: book, volumeName: volume)
                } else {
                    content(book: book)
                }
            }
            .task(id: bookID) { await playback.open(book) }
            .sheet(item: $diffChapter) { chapter in
                SummaryDiffView(chapterTitle: chapter.title, originalText: chapter.cleanedText, summaryText: chapter.summarizedText ?? "")
            }
        } else {
            EmptyStateCard(systemImage: "questionmark.folder", title: "Buch nicht gefunden")
        }
    }

    // MARK: Layout

    private func content(book: BookProject) -> some View {
        PlayerLayout(
            book: book,
            coordinator: playback.coordinator,
            showChapters: showChapters,
            showText: showText,
            onDiff: { diffChapter = $0 }
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 4)
        .animation(Theme.Motion.flow, value: showChapters)
        .animation(Theme.Motion.flow, value: showText)
        // Reading and studying need room: switching there from a small
        // listening window widens the window (it never shrinks it).
        .onChange(of: showChapters) { _, _ in WindowSizer.ensureWidth(for: showChapters, text: showText) }
        .onChange(of: showText) { _, _ in WindowSizer.ensureWidth(for: showChapters, text: showText) }
        .toolbar { toolbar(book: book) }
        .navigationTitle(book.title)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.space) {
            playback.coordinator.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            playback.coordinator.skip(by: -15)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            playback.coordinator.skip(by: 30)
            return .handled
        }
        .onChange(of: book.chapters.map(\.audioStatus)) { oldStatuses, newStatuses in
            // Regenerated chapter files appear → reload (chapter-file mode).
            guard oldStatuses != newStatuses,
                  zip(oldStatuses, newStatuses).contains(where: { $0.0 != .ready && $0.1 == .ready }),
                  playback.bookID == bookID,
                  !playback.coordinator.isPackagedMode else { return }
            let sorted = book.sortedChapters
            playback.coordinator.reload(chapterURLs: sorted.compactMap(\.audioFileURL),
                                        segments: sorted.map { $0.audioSegments ?? [] },
                                        chapterDurations: sorted.map { $0.audioDurationSeconds ?? 0 })
        }
        .alert("Hörbuch umbenennen", isPresented: $showRenameBook) {
            TextField("Titel", text: $renameBookTitle)
            Button("Abbrechen", role: .cancel) {
                renameBookTitle = ""
            }
            Button("Speichern") {
                let trimmed = renameBookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, var updated = libraryStore.book(id: bookID), updated.title != trimmed {
                    updated.title = trimmed
                    libraryStore.upsert(updated)
                    libraryStore.flush()
                }
                renameBookTitle = ""
            }
        } message: {
            Text("Gib einen neuen Namen für das Hörbuch ein.")
        }
        .onChange(of: playback.ambient.scene) { _, scene in persistAmbient(scene: scene) }
        .onChange(of: playback.ambient.volume) { _, _ in persistAmbient(scene: playback.ambient.scene) }
    }

    @ToolbarContentBuilder
    private func toolbar(book: BookProject) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            let overScene = playback.ambient.scene != nil && playback.bookID == book.id
            VStack(alignment: .leading, spacing: 0) {
                Text(book.title)
                    .flowFont(.callout, weight: .semibold)
                    .foregroundStyle(overScene ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .flowFont(.caption)
                        .foregroundStyle(overScene ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(overScene ? 0.7 : 0), radius: 4, y: 1)
            // The toolbar sizes items by their ideal width: keep it modest so
            // a long title truncates instead of pushing the mode switch into
            // the overflow menu in narrow windows.
            .frame(minWidth: 80, idealWidth: 200, maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 6)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) {
            SegmentedPills(selection: presetBinding, options: LayoutPreset.allCases.map {
                PillOption(value: Optional($0), label: $0.label, systemImage: $0.systemImage)
            }, size: .small)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showChapters) {
                Label("Kapitel", systemImage: "list.bullet")
            }
            .help("Kapitelliste ein-/ausblenden")
            Toggle(isOn: $showText) {
                Label("Mitlesen", systemImage: "text.alignleft")
            }
            .help("Mitlese-Text ein-/ausblenden")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    renameBookTitle = book.title
                    showRenameBook = true
                } label: {
                    Label("Hörbuch umbenennen …", systemImage: "pencil")
                }
                if book.status == .completed {
                    Button {
                        NotificationCenter.default.post(name: .openRevoice, object: book.id)
                    } label: {
                        Label("Neu vertonen …", systemImage: "waveform.badge.mic")
                    }
                }
                if let outputURL = book.outputDirectoryURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    } label: {
                        Label("Im Finder zeigen", systemImage: "folder")
                    }
                }
                Button {
                    reassignOutput(book: book)
                } label: {
                    Label("Audiodatei neu zuordnen …", systemImage: "link")
                }
            } label: {
                Label("Mehr", systemImage: "ellipsis")
            }
        }
    }

    private var presetBinding: Binding<LayoutPreset?> {
        Binding(
            get: { LayoutPreset.allCases.first { $0.panes == (showChapters, showText) } },
            set: { preset in
                guard let preset else { return }
                withAnimation(Theme.Motion.flow) {
                    showChapters = preset.panes.chapters
                    showText = preset.panes.text
                }
            }
        )
    }

    private func persistAmbient(scene: AmbientSound?) {
        guard playback.bookID == bookID, var updated = libraryStore.book(id: bookID) else { return }
        let raw = scene?.rawValue
        let percent = scene == nil ? nil : Int((playback.ambient.volume * 100).rounded())
        guard updated.ambientSound != raw || updated.ambientVolumePercent != percent else { return }
        updated.ambientSound = raw
        updated.ambientVolumePercent = percent
        libraryStore.upsert(updated)
    }

    // MARK: Missing source (offline volume)

    private func missingSourceView(book: BookProject, volumeName: String) -> some View {
        EmptyStateCard(
            systemImage: "externaldrive.badge.exclamationmark",
            title: "Audiodatei nicht gefunden",
            message: volumeName.isEmpty
                ? "Die fertige Audiodatei und die Kapiteldateien sind nicht erreichbar. Ist das Ausgabe-Volume verbunden?"
                : "Die fertige Audiodatei ist nicht erreichbar — Volume „\(volumeName)“ verbunden? Anschließend hier neu zuordnen."
        ) {
            HStack(spacing: 10) {
                Button("Erneut versuchen") { Task { await playback.reload(book) } }
                    .buttonStyle(.flowSecondary)
                Button("Datei neu zuordnen …") { reassignOutput(book: book) }
                    .buttonStyle(.flowProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(book.title)
    }

    /// Lets the user point the book at the packaged file again (e.g. after
    /// the external volume was mounted under a different path). Purely a
    /// reference update — no files are touched.
    private func reassignOutput(book: BookProject) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.audio]
        panel.message = "Fertige Audiodatei (M4B/M4A) dieses Buches auswählen"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard var updated = libraryStore.book(id: bookID) else { return }
                let bookmark = (try? url.bookmarkData()) ?? Data()
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
                updated.packagedAudio = PackagedAudioInfo(url: url, bookmarkData: bookmark, sizeBytes: size, verifiedAt: Date())
                libraryStore.upsert(updated)
                await playback.reload(updated)
            }
        }
    }
}

// MARK: - Layout (observes the coordinator)

private struct PlayerLayout: View {
    let book: BookProject
    /// Not observed: only the leaf views that show time observe the clock.
    let coordinator: AudioPlayerCoordinator
    let showChapters: Bool
    let showText: Bool
    var onDiff: (Chapter) -> Void
    /// Opening the book: pages swing open from the spine on appear.
    @State private var opened = false

    var body: some View {
        // Decide the bar layout from the width the window OFFERS (the
        // GeometryReader's proposal). Measuring the bar itself can't work:
        // the wide variant never shrinks below ~1000 pt, so it would stay
        // wide and push the panes over the sidebar and out of the window.
        GeometryReader { proxy in
            // Study needs room for both panes: in a narrow window it falls
            // back to reading (the contents come back with the space).
            let chaptersFit = !showText || proxy.size.width >= 700
            let chapters = showChapters && chaptersFit
            let columnWidth = proxy.size.width - (chapters ? 304 : 0)
            content(barIsNarrow: columnWidth < 1000, showChapters: chapters)
        }
    }

    private func content(barIsNarrow: Bool, showChapters: Bool) -> some View {
        HStack(spacing: 14) {
            if showChapters {
                ChapterListPane(book: book, coordinator: coordinator, onDiff: onDiff)
                    .frame(width: 290)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if showText {
                VStack(spacing: 12) {
                    ReaderPane(book: book, coordinator: coordinator)
                        .rotation3DEffect(.degrees(opened ? 0 : -32), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
                        .opacity(opened ? 1 : 0)
                    PlayerBar(book: book, coordinator: coordinator, isNarrow: barIsNarrow)
                        .offset(y: opened ? 0 : 30)
                        .opacity(opened ? 1 : 0)
                }
                .transition(.asymmetric(insertion: .pageTurn, removal: .opacity))
            } else {
                PlayerStage(book: book, coordinator: coordinator)
                    .scaleEffect(opened ? 1 : 0.94)
                    .opacity(opened ? 1 : 0)
                    .transition(.opacity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.05)) { opened = true }
        }
    }
}

// MARK: - Big stage ("Hören")

private struct PlayerStage: View {
    let book: BookProject
    let coordinator: AudioPlayerCoordinator

    @Environment(PlaybackSession.self) private var playback

    /// Over an ambient scene the text sits on a picture, not on the app
    /// background — always light, with a shadow, in either appearance.
    private var overScene: Bool { playback.ambient.scene != nil && playback.bookID == book.id }

    var body: some View {
        GeometryReader { proxy in
            // Sized from the space actually there (v3.2): the controls always
            // fit; the subtitle goes first, the cover takes what is left.
            let compact = proxy.size.height < 560 || proxy.size.width < 560
            let panelHeight: CGFloat = compact ? 150 : 214
            let titleHeight: CGFloat = compact ? 44 : 64
            let showsSubtitle = proxy.size.height >= 620
            let spacing: CGFloat = compact ? 12 : 22
            let fixed = panelHeight + titleHeight + (showsSubtitle ? 66 : 0) + spacing * 3 + 40
            let coverHeight = max(0, proxy.size.height - fixed)
            let coverWidth = min(300, coverHeight * 0.72, proxy.size.width * 0.5)
            VStack(spacing: spacing) {
                Spacer(minLength: compact ? 4 : 8)
                if coverWidth >= 64 {
                    StageCoverView(book: book, width: coverWidth, coordinator: coordinator)
                }
                StageTitleBlock(book: book, coordinator: coordinator, compact: compact, overScene: overScene)

                // Subtitle pill: only here, where the text pane is closed
                // (audit finding 4 — no duplicate next to the read-along).
                if showsSubtitle {
                    StageSubtitleBlock(coordinator: coordinator)
                }

                VStack(spacing: compact ? 10 : 18) {
                    FlowScrubber(coordinator: coordinator)
                    TransportControls(coordinator: coordinator, large: !compact)
                    SecondaryControls(coordinator: coordinator, compact: compact)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, compact ? 16 : 26)
                .padding(.vertical, compact ? 12 : 22)
                .flowSurface(cornerRadius: compact ? 22 : 30)
                .padding(.horizontal, 12)
                .layoutPriority(1)
                Spacer(minLength: compact ? 8 : 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StageCoverView: View {
    let book: BookProject
    let width: CGFloat
    @ObservedObject var coordinator: AudioPlayerCoordinator

    var body: some View {
        BookCoverView(book: book, width: width)
            .scaleEffect(coordinator.isPlaying ? 1.0 : 0.96)
            .animation(Theme.Motion.flow, value: coordinator.isPlaying)
    }
}

private struct StageTitleBlock: View {
    let book: BookProject
    @ObservedObject var coordinator: AudioPlayerCoordinator
    let compact: Bool
    let overScene: Bool

    private var chapter: Chapter? {
        let chapters = book.sortedChapters
        return chapters.indices.contains(coordinator.currentChapterIndex) ? chapters[coordinator.currentChapterIndex] : nil
    }

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            Text(chapter?.title ?? book.title)
                .flowFont(compact ? .headline : .title2)
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 1 : 2)
            Text(chapterContext)
                .flowFont(compact ? .caption : .callout)
                .foregroundStyle(overScene ? AnyShapeStyle(Color.white.opacity(0.78)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .foregroundStyle(overScene ? Color.white : Color.primary)
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(overScene ? 0.7 : 0.25), radius: 6, y: 1)
    }

    private var chapterContext: String {
        var parts = [String(localized: "Kapitel \(coordinator.currentChapterIndex + 1) von \(max(coordinator.chapterCount, book.sortedChapters.count))")]
        if let group = chapter?.groupTitle, !group.isEmpty, group != chapter?.title { parts.append(group) }
        let remaining = coordinator.bookDuration - coordinator.bookElapsed
        if remaining > 1 { parts.append(String(localized: "Buch: noch \(ListeningTimeFormatter.long(remaining))")) }
        return parts.joined(separator: " · ")
    }
}

private struct StageSubtitleBlock: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator

    var body: some View {
        SubtitlePill(text: coordinator.currentSegmentText)
            .frame(maxWidth: 620)
            .padding(.horizontal, 16)
    }
}

private struct SubtitlePill: View {
    let text: String?

    var body: some View {
        ZStack {
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 15, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .flowGlass(cornerRadius: 18)
                    .id(text)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(minHeight: 44)
        .animation(.easeInOut(duration: 0.35), value: text)
    }
}

// MARK: - Compact bar ("Lesen"/"Lernen")

private struct PlayerBar: View {
    let book: BookProject
    let coordinator: AudioPlayerCoordinator

    /// Decided by the parent from the width it offers — not `ViewThatFits`,
    /// which re-measures both layouts on every playback tick.
    let isNarrow: Bool

    var body: some View {
        Group {
            if isNarrow { narrow } else { wide }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .flowGlass(cornerRadius: 26)
    }

    private var wide: some View {
        HStack(spacing: 18) {
            nowPlaying.frame(width: 220, alignment: .leading)
            TransportControls(coordinator: coordinator, large: false)
            FlowScrubber(coordinator: coordinator, compact: true)
                .frame(minWidth: 220)
            SecondaryControls(coordinator: coordinator)
        }
    }

    private var narrow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                nowPlaying
                Spacer(minLength: 8)
                TransportControls(coordinator: coordinator, large: false)
            }
            HStack(spacing: 12) {
                FlowScrubber(coordinator: coordinator, compact: true)
                SecondaryControls(coordinator: coordinator, compact: true)
            }
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            BookCoverView(book: book, width: 34)
            BarNowPlayingTitle(book: book, coordinator: coordinator)
        }
    }
}

private struct BarNowPlayingTitle: View {
    let book: BookProject
    @ObservedObject var coordinator: AudioPlayerCoordinator

    private var chapterTitle: String {
        let chapters = book.sortedChapters
        return chapters.indices.contains(coordinator.currentChapterIndex) ? chapters[coordinator.currentChapterIndex].title : book.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(chapterTitle)
                .flowFont(.callout, weight: .semibold)
                .lineLimit(1)
            Text("Kapitel \(coordinator.currentChapterIndex + 1) von \(max(coordinator.chapterCount, book.sortedChapters.count))")
                .flowFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}


// MARK: - Controls

private struct TransportControls: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator
    var large: Bool
    @Environment(\.flowAccent) private var accent

    var body: some View {
        HStack(spacing: large ? 22 : 12) {
            button("backward.end.fill", "Kapitelanfang / vorheriges Kapitel", size: large ? 17 : 13) { coordinator.previousChapter() }
            button("gobackward.15", "15 Sekunden zurück (←)", size: large ? 20 : 15) { coordinator.skip(by: -15) }
            Button {
                coordinator.togglePlayPause()
            } label: {
                Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 26 : 17, weight: .bold))
                    .foregroundStyle(accent.onAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: large ? 66 : 42, height: large ? 66 : 42)
                    .background(Circle().fill(accent.fill))
                    .shadow(color: accent.color.opacity(0.45), radius: large ? 14 : 7, y: large ? 6 : 3)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(coordinator.isPlaying ? "Pause (Leertaste)" : "Wiedergabe (Leertaste)")
            .accessibilityLabel(coordinator.isPlaying ? "Pause" : "Wiedergabe")
            button("goforward.30", "30 Sekunden vor (→)", size: large ? 20 : 15) { coordinator.skip(by: 30) }
            button("forward.end.fill", "Nächstes Kapitel", size: large ? 17 : 13) { coordinator.nextChapter() }
        }
    }

    private func button(_ symbol: String, _ help: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 1.9, height: size * 1.9)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Subtle press feedback for icon buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// Rate, sleep timer and ambience — fixed sizes, no layout jumps.
private struct SecondaryControls: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator
    /// Small windows: the ambience button shows its icon only.
    var compact: Bool = false
    @Environment(PlaybackSession.self) private var playback
    @State private var showAmbient = false
    @AppStorage("window.alwaysOnTop") private var alwaysOnTop = false

    private let rates: [Double] = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Tempo", selection: Binding(get: { coordinator.rate }, set: { coordinator.setRate($0) })) {
                    ForEach(rates, id: \.self) { rate in
                        Text(Self.rateLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(Self.rateLabel(coordinator.rate))
                    .flowFont(.callout, weight: .semibold)
                    .monospacedDigit()
                    .frame(width: 46, height: 30)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .glassEffect(.regular.interactive(), in: Capsule())
            .fixedSize()
            .help("Wiedergabetempo")

            Menu {
                Picker("Schlaf-Timer", selection: Binding(
                    get: { playback.sleepTimerEnd == nil ? 0 : -1 },
                    set: { playback.setSleepTimer(minutes: $0 > 0 ? $0 : nil) }
                )) {
                    Text("Aus").tag(0)
                    ForEach([10, 15, 30, 45, 60, 90], id: \.self) { minutes in
                        Text("\(minutes) Minuten").tag(minutes)
                    }
                    if playback.sleepTimerEnd != nil { Text("Aktiv").tag(-1) }
                }
                .pickerStyle(.inline)
            } label: {
                SleepLabel(end: playback.sleepTimerEnd)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .glassEffect(playback.sleepTimerEnd == nil ? .regular.interactive() : .regular.tint(Color.accentColor.opacity(0.35)).interactive(), in: Capsule())
            .fixedSize()
            .help("Schlaf-Timer — das Ambiente brennt mit herunter")

            Button {
                showAmbient.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: playback.ambient.scene?.systemImage ?? "sparkles")
                    if !compact {
                        Text(playback.ambient.scene?.displayName ?? L("Ambiente"))
                            .flowFont(.callout, weight: .medium)
                            .lineLimit(1)
                    }
                }
                .frame(width: compact ? 40 : 156, height: 30)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(playback.ambient.scene == nil ? .regular.interactive() : .regular.tint(Color.orange.opacity(0.0)).interactive(), in: Capsule())
            .foregroundStyle(playback.ambient.scene == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            .popover(isPresented: $showAmbient, arrowEdge: .bottom) {
                AmbientPicker(controller: playback.ambient, bookIsPlaying: coordinator.isPlaying)
            }
            .help("Ambiente: Kaminfeuer, Regen, Gewitter, Meer, Bach, Dschungel")

            Button {
                alwaysOnTop.toggle()
                NSApp.setAlwaysOnTop(alwaysOnTop)
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(alwaysOnTop ? .regular.tint(Color.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: Circle())
            .foregroundStyle(alwaysOnTop ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .help(alwaysOnTop ? "Immer im Vordergrund (aktiv)" : "Immer im Vordergrund anheften")
        }
    }

    static func rateLabel(_ rate: Double) -> String {
        let formatted = rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%g", rate)
        return formatted.replacingOccurrences(of: ".", with: ",") + "×"
    }
}

private struct SleepLabel: View {
    let end: Date?

    var body: some View {
        Group {
            if let end {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let minutes = max(0, Int(ceil(end.timeIntervalSince(context.date) / 60)))
                    Label("\(minutes) Min.", systemImage: "moon.zzz.fill")
                }
            } else {
                Image(systemName: "moon.zzz")
            }
        }
        .flowFont(.callout, weight: .medium)
        .monospacedDigit()
        .frame(minWidth: 34, minHeight: 30)
        .padding(.horizontal, end == nil ? 0 : 8)
    }
}

/// Ambient scene picker (popover): scenes, intensity, volume.
struct AmbientPicker: View {
    let controller: AmbientController
    var bookIsPlaying: Bool
    @Environment(\.flowAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Ambiente").flowFont(.headline)
                Spacer()
                if controller.scene != nil {
                    Button("Aus") { controller.select(nil, bookIsPlaying: bookIsPlaying) }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 10), count: 3), spacing: 10) {
                ForEach(AmbientSound.allCases) { scene in
                    let selected = controller.scene == scene
                    Button {
                        controller.select(selected ? nil : scene, bookIsPlaying: bookIsPlaying)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: scene.systemImage)
                                .font(.system(size: 20))
                                .symbolRenderingMode(.hierarchical)
                                .frame(height: 24)
                            Text(scene.displayName)
                                .flowFont(.caption, weight: selected ? .semibold : .regular)
                        }
                        .frame(width: 84, height: 66)
                        .foregroundStyle(selected ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(.primary))
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selected ? AnyShapeStyle(accent.fill) : AnyShapeStyle(Color.primary.opacity(0.05)))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                labeledSlider("Intensität", systemImage: "flame", value: Binding(get: { controller.intensity }, set: { controller.setIntensity($0) }))
                labeledSlider("Lautstärke", systemImage: "speaker.wave.2", value: Binding(get: { controller.volume }, set: { controller.setVolume($0) }))
            }
            .disabled(controller.scene == nil)
            .opacity(controller.scene == nil ? 0.5 : 1)
            Text("Läuft nur in der App mit — nie im exportierten Hörbuch. Pausiert mit dem Buch.")
                .flowFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 300)
        .tint(accent.color)
    }

    private func labeledSlider(_ title: String, systemImage: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(L(title)).flowFont(.callout).frame(width: 74, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
    }
}

// MARK: - Scrubber

/// Chapter scrubber: accent-filled capsule, knob on hover/drag, elapsed and
/// remaining time. Dragging previews locally and seeks on release.
struct FlowScrubber: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator
    var compact: Bool = false

    @State private var dragFraction: Double?
    @State private var hovering = false
    @Environment(\.flowAccent) private var accent

    private var duration: Double { coordinator.chapterDuration }
    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(max(coordinator.chapterElapsed / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: compact ? 4 : 7) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let active = hovering || dragFraction != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [accent.color, accent.gradientPartner], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, width * fraction))
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .frame(width: active ? 14 : 0, height: active ? 14 : 0)
                        .offset(x: width * fraction - (active ? 7 : 0))
                }
                .frame(height: active ? 7 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / max(width, 1), 0), 1)
                        }
                        .onEnded { value in
                            let target = min(max(value.location.x / max(width, 1), 0), 1)
                            coordinator.seekInChapter(to: target * duration)
                            dragFraction = nil
                        }
                )
                .animation(Theme.Motion.quick, value: active)
            }
            .frame(height: 16)
            .onHover { hovering = $0 }
            .accessibilityElement()
            .accessibilityLabel("Position im Kapitel")
            .accessibilityValue(ListeningTimeFormatter.clock(fraction * duration))
            .accessibilityAdjustableAction { direction in
                coordinator.skip(by: direction == .increment ? 30 : -15)
            }

            HStack {
                Text(ListeningTimeFormatter.clock(fraction * duration))
                Spacer()
                Text("−" + ListeningTimeFormatter.clock(max(0, duration - fraction * duration)))
            }
            .flowFont(.caption, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
}

/// Grows the window when a layout needs more width than it has.
@MainActor
enum WindowSizer {
    /// Window widths the layouts need to look right (sidebar folded).
    static func minimumWidth(chapters: Bool, text: Bool) -> CGFloat {
        switch (chapters, text) {
        case (true, true): return 1000
        case (false, true), (true, false): return 780
        case (false, false): return 0
        }
    }

    static func ensureWidth(for chapters: Bool, text: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, !window.styleMask.contains(.fullScreen) else { return }
        let needed = minimumWidth(chapters: chapters, text: text)
        var frame = window.frame
        guard frame.width < needed, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        frame.size.width = min(needed, screen.width)
        // Grow to the right; slide left only if the screen edge forces it.
        frame.origin.x = min(frame.origin.x, screen.maxX - frame.width)
        frame.origin.x = max(frame.origin.x, screen.minX)
        window.setFrame(frame, display: true, animate: true)
    }
}
