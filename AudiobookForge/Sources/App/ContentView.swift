import SwiftUI
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    /// Library shelf (continue listening, all books, import).
    case home
    case book(UUID)
    case settings(SettingsPane)

    var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PipelineController.self) private var pipelineController
    @Environment(PlaybackSession.self) private var playback
    @Environment(\.colorScheme) private var colorScheme

    @State private var selection: SidebarSelection? = .home
    @State private var importError: String?
    /// Files currently being read in (shown right away, so a large
    /// textbook doesn't look like nothing happened).
    @State private var importingFiles: [String] = []
    @State private var isDropTargeted = false
    @AppStorage("sidebar.visible") private var sidebarVisible = true
    /// Window width; below 820 pt the sidebar folds away by itself (the
    /// stored preference stays) and the toggle shows it just for now.
    @State private var windowWidth: CGFloat = 1320
    @State private var narrowSidebarShown = false
    private var isNarrow: Bool { windowWidth < 820 }
    private var showsSidebar: Bool { isNarrow ? narrowSidebarShown : sidebarVisible }
    @State private var showSetup = false
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 290
    @AppStorage("window.alwaysOnTop") private var alwaysOnTop = false

    private var accent: AppAccent { settingsStore.settings.accent }
    private var textScale: Double { Theme.textScale(for: settingsStore.settings.textSizeStep) }

    /// The ambience paints the whole window only while its book is open.
    /// Energy profile in force (adapter/battery, macOS Low Power Mode).
    private var powerMode: PowerMode { PowerMonitor.shared.mode(for: settingsStore.settings) }

    private var ambientMotionAllowed: Bool {
        !reduceMotion && settingsStore.settings.motionMode == .system && powerMode.animates
    }

    private var showsAmbientVisuals: Bool {
        guard playback.ambient.scene != nil, let bookID = playback.bookID else { return false }
        return selection == .book(bookID)
    }

    var body: some View {
        ZStack {
            FlowBackground()
                .environment(\.backgroundMood, showsAmbientVisuals ? playback.ambient.mood : nil)

            if showsAmbientVisuals, let scene = playback.ambient.scene {
                PixelSceneView(scene: scene, intensity: playback.ambient.intensity, animated: ambientMotionAllowed,
                               contentOffsetX: 0,
                               lastFlash: playback.ambient.lastFlash)
                    .ignoresSafeArea()
                .transition(.opacity)
            }

            // One continuous surface: sidebar and content share the same
            // background with no divider (user decision 2026-10-19).
            HStack(spacing: 0) {
                if showsSidebar {
                    SidebarView(selection: $selection, importingFiles: importingFiles, onImport: importDocuments)
                        .frame(width: sidebarWidth)
                        .background {
                            if showsAmbientVisuals {
                                ambientSidebarBackground
                            }
                        }
                        .overlay(alignment: .trailing) { SidebarResizeHandle(width: $sidebarWidth) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                // minWidth 0: a page that can't shrink far enough overflows to
                // the right instead of shoving the sidebar out of the window.
                detailView
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(Theme.Motion.flow) {
                            if isNarrow { narrowSidebarShown.toggle() } else { sidebarVisible.toggle() }
                        }
                    } label: {
                        Label("Seitenleiste", systemImage: "sidebar.left")
                    }
                    .help("Seitenleiste ein-/ausblenden (⌃⌘S)")
                    .keyboardShortcut("s", modifiers: [.control, .command])
                }
            }

            if showsAmbientVisuals, powerMode.animates, let scene = playback.ambient.scene {
                PixelSceneGlow(scene: scene, intensity: playback.ambient.intensity, animated: ambientMotionAllowed,
                               lastFlash: playback.ambient.lastFlash, burnDownEnd: playback.ambient.burnDownEnd)
                    .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if isDropTargeted {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: showsAmbientVisuals)
        .animation(.easeInOut(duration: 0.8), value: playback.ambient.scene)
        .animation(Theme.Motion.quick, value: isDropTargeted)
        .animation(Theme.Motion.flow, value: isNarrow)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            windowWidth = width
            if width >= 820 { narrowSidebarShown = false }
        }
        .onDrop(of: [.pdf, .epubDocument, .fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .preferredColorScheme(colorSchemeOverride)
        .dynamicTypeSize(Theme.dynamicTypeSize(for: settingsStore.settings.textSizeStep))
        .environment(\.appTextScale, textScale)
        .environment(\.flowAccent, accent)
        .environment(\.energyAnimates, powerMode.animates)
        .environment(\.surfaceLevel, SurfaceLevel(intensity: settingsStore.settings.glassIntensity))
        .font(.system(size: 13 * textScale))
        .tint(accent.color)
        .onChange(of: settingsStore.settings.appearanceMode) { _, newValue in applyAppearance(newValue) }
        .onChange(of: alwaysOnTop) { _, newValue in applyAlwaysOnTop(newValue) }
        .onAppear {
            applyAppearance(settingsStore.settings.appearanceMode)
            if alwaysOnTop { applyAlwaysOnTop(true) }
            if SetupAssistantView.shouldShowAutomatically { showSetup = true }
        }
        .sheet(isPresented: $showSetup) {
            SetupAssistantView()
                .environment(\.flowAccent, accent)
                .tint(accent.color)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSetupAssistant)) { _ in showSetup = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            playback.savePosition()
        }
        .overlay(alignment: .top) { migrationBanner }
        .alert("Import fehlgeschlagen", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .focusedSceneValue(\.navigateTo, { selection = $0 })
        .focusedSceneValue(\.importDocuments, importDocuments)
        #if DEBUG
        .modifier(DebugAutomationReceiver(selection: $selection, importDocuments: importDocuments))
        #endif
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .none, .home:
            LibraryHomeView(selection: $selection, importingFiles: importingFiles, onImport: importDocuments)
        case .settings(let pane):
            SettingsView(pane: pane)
        case .book(let id):
            if libraryStore.book(id: id) != nil {
                BookDetailView(bookID: id)
            } else {
                LibraryHomeView(selection: $selection, importingFiles: importingFiles, onImport: importDocuments)
            }
        }
    }

    @ViewBuilder
    private var migrationBanner: some View {
        if let notice = libraryStore.migrationNotice {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(notice)
                    .flowFont(.callout)
                    .lineLimit(3)
                Spacer()
                Button("OK") { libraryStore.migrationNotice = nil }
                    .buttonStyle(.flowSecondary)
            }
            .padding(14)
            .flowGlass(cornerRadius: 18)
            .padding(.horizontal, 80)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var colorSchemeOverride: ColorScheme? {
        switch settingsStore.settings.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var isDarkMode: Bool {
        colorSchemeOverride == .dark || (colorSchemeOverride == nil && colorScheme == .dark)
    }

    private var ambientSidebarBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(isDarkMode ? Color.black.opacity(0.60) : Color.white.opacity(0.65))
            Rectangle().fill(accent.color.opacity(isDarkMode ? 0.20 : 0.15))
        }
        .ignoresSafeArea(edges: .vertical)
    }

    /// NSApp.appearance keeps native panels (open/save dialogs) consistent
    /// with the chosen mode (plan 9.2).
    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyAlwaysOnTop(_ onTop: Bool) {
        NSApp.setAlwaysOnTop(onTop)
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ["pdf", "epub"].contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in importDocuments([url]) }
            }
        }
    }

    private func importDocuments(_ urls: [URL]) {
        for url in urls {
            let name = url.lastPathComponent
            importingFiles.append(name)
            let settings = settingsStore.settings
            Task {
                defer { importingFiles.removeAll { $0 == name } }
                do {
                    // Off the main actor: extraction of a large textbook
                    // takes seconds.
                    let book = try await Task.detached(priority: .userInitiated) {
                        try await DocumentImportService.importDocument(at: url, settings: settings)
                    }.value
                    libraryStore.upsert(book)
                    selection = .book(book.id)
                } catch {
                    importError = "\(name): \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Invisible drag handle on the sidebar's trailing edge (no divider line).
/// Divider between sidebar and content, doubling as the resize grip: a
/// hairline that fades out toward the window edges (no hard panel border,
/// the background stays one surface) and firms up in the accent colour
/// while hovered or dragged.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var isHovered = false
    @Environment(\.flowAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    private var isActive: Bool { isHovered || start != nil }

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(LinearGradient(
                    stops: [
                        .init(color: lineColor.opacity(0), location: 0.04),
                        .init(color: lineColor, location: 0.18),
                        .init(color: lineColor, location: 0.82),
                        .init(color: lineColor.opacity(0), location: 0.98),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: isActive ? 2 : 1)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .animation(Theme.Motion.flow, value: isActive)
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if start == nil { start = width }
                    width = min(440, max(230, (start ?? width) + value.translation.width))
                }
                .onEnded { _ in start = nil }
        )
        .offset(x: 4)
    }

    private var lineColor: Color {
        isActive ? accent.color.opacity(0.7) : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10)
    }
}

/// Full-window drop target shown while files hover over the window.
private struct DropOverlay: View {
    @Environment(\.flowAccent) private var accent

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(0.85)
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(accent.color.opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [14, 10]))
                .padding(28)
            VStack(spacing: 14) {
                AppIconTile(systemImage: "arrow.down.doc.fill", size: 84)
                Text("Loslassen zum Importieren")
                    .flowFont(.title)
                Text("PDF und EPUB · mehrere Dateien gleichzeitig möglich")
                    .flowFont(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Menu commands → scene

struct NavigateToKey: FocusedValueKey {
    typealias Value = (SidebarSelection) -> Void
}

struct ImportDocumentsKey: FocusedValueKey {
    typealias Value = ([URL]) -> Void
}

extension FocusedValues {
    var navigateTo: NavigateToKey.Value? {
        get { self[NavigateToKey.self] }
        set { self[NavigateToKey.self] = newValue }
    }
    var importDocuments: ImportDocumentsKey.Value? {
        get { self[ImportDocumentsKey.self] }
        set { self[ImportDocumentsKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Reopens the setup assistant (Settings → Diagnose).
    static let openSetupAssistant = Notification.Name("ABFOpenSetupAssistant")
}

extension UTType {
    static var epubDocument: UTType { UTType(filenameExtension: "epub") ?? .data }
}

extension NSApplication {
    func setAlwaysOnTop(_ onTop: Bool) {
        for window in windows {
            if window.canBecomeMain {
                window.level = onTop ? .floating : .normal
            }
        }
    }
}
