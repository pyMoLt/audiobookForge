import XCTest
import SwiftUI
import AppKit
@testable import AudiobookForge

@MainActor
final class VisualAuditSnapshotTests: XCTestCase {
    private var outputDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VisualAuditSnapshotTests.swift -> AudiobookForgeTests
            .deletingLastPathComponent() // -> AudiobookForge
            .deletingLastPathComponent() // -> audiobookSwift
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("audit_screenshots_aktuell", isDirectory: true)
    }

    private func render<V: View>(
        _ view: V,
        size: CGSize,
        appearance: NSAppearance.Name = .aqua,
        to filename: String
    ) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = (appearance == .darkAqua) ? NSColor(calibratedWhite: 0.12, alpha: 1.0) : NSColor.windowBackgroundColor

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        // Wait a tick for SwiftUI layout
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Could not create bitmap rep for \(filename)")
            return
        }
        bitmapRep.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            XCTFail("Could not create PNG data for \(filename)")
            return
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let fileURL = outputDir.appendingPathComponent(filename)
        try pngData.write(to: fileURL)
        print("Wrote snapshot: \(fileURL.path)")
    }

    func testRenderSettingsAppearanceTab() throws {
        let settingsStore = SettingsStore()
        
        let light = ScrollView {
            PillSection("Erscheinungsbild") {
                AppearanceSettingsSection()
            }
            .padding(24)
        }
        .environment(settingsStore)
        .frame(width: 600, height: 700)
        try render(light, size: CGSize(width: 600, height: 700), appearance: .aqua, to: "settings_appearance_tab_light.png")

        let dark = ScrollView {
            PillSection("Erscheinungsbild") {
                AppearanceSettingsSection()
            }
            .padding(24)
        }
        .environment(settingsStore)
        .frame(width: 600, height: 700)
        try render(dark, size: CGSize(width: 600, height: 700), appearance: .darkAqua, to: "settings_appearance_tab_dark.png")
    }

    func testRenderSettingsLightAndDark() throws {
        let settingsStore = SettingsStore()
        
        // 1. Settings Light
        let settingsLight = SettingsView()
            .environment(settingsStore)
            .frame(width: 800, height: 900)
        try render(settingsLight, size: CGSize(width: 800, height: 900), appearance: .aqua, to: "settings_light.png")

        // 2. Settings Dark
        settingsStore.settings.appearanceMode = .dark
        let settingsDark = SettingsView()
            .environment(settingsStore)
            .frame(width: 800, height: 900)
        try render(settingsDark, size: CGSize(width: 800, height: 900), appearance: .darkAqua, to: "settings_dark.png")
    }

    func testRenderSettingsAccentsAndTextSizes() throws {
        let settingsStore = SettingsStore()

        // 1. Accent Coral
        settingsStore.settings.accent = .coral
        let settingsCoral = SettingsView()
            .environment(settingsStore)
            .frame(width: 800, height: 900)
        try render(settingsCoral, size: CGSize(width: 800, height: 900), appearance: .aqua, to: "settings_accent_coral.png")

        // 2. Accent Teal
        settingsStore.settings.accent = .teal
        let settingsTeal = SettingsView()
            .environment(settingsStore)
            .frame(width: 800, height: 900)
        try render(settingsTeal, size: CGSize(width: 800, height: 900), appearance: .aqua, to: "settings_accent_teal.png")

        // 3. Text size XS
        settingsStore.settings.accent = .violet
        settingsStore.settings.textSizeStep = .xs
        let settingsXS = SettingsView()
            .environment(settingsStore)
            .environment(\.appTextScale, Theme.textScale(for: .xs))
            .frame(width: 800, height: 900)
        try render(settingsXS, size: CGSize(width: 800, height: 900), appearance: .aqua, to: "settings_textsize_xs.png")

        // 4. Text size XXL
        settingsStore.settings.textSizeStep = .xxl
        let settingsXXL = SettingsView()
            .environment(settingsStore)
            .environment(\.appTextScale, Theme.textScale(for: .xxl))
            .frame(width: 800, height: 900)
        try render(settingsXXL, size: CGSize(width: 800, height: 900), appearance: .aqua, to: "settings_textsize_xxl.png")
    }

    func testRenderVoiceGallery() throws {
        let settingsStore = SettingsStore()

        // Voice Gallery Light
        let galleryLight = VoiceGalleryView()
            .environment(settingsStore)
            .frame(width: 700, height: 800)
        try render(galleryLight, size: CGSize(width: 700, height: 800), appearance: .aqua, to: "voice_gallery_sheet_light.png")

        // Voice Gallery Dark
        let galleryDark = VoiceGalleryView()
            .environment(settingsStore)
            .frame(width: 700, height: 800)
        try render(galleryDark, size: CGSize(width: 700, height: 800), appearance: .darkAqua, to: "voice_gallery_sheet_dark.png")
    }

    func testRenderFlowBackgroundRasterization() throws {
        let settingsStore = SettingsStore()

        // 1. Violet Light
        settingsStore.settings.accent = .violet
        let bgVioletLight = FlowBackground()
            .environment(settingsStore)
            .frame(width: 800, height: 600)
        try render(bgVioletLight, size: CGSize(width: 800, height: 600), appearance: .aqua, to: "flow_bg_violet_light.png")

        // 2. Violet Dark
        let bgVioletDark = FlowBackground()
            .environment(settingsStore)
            .frame(width: 800, height: 600)
        try render(bgVioletDark, size: CGSize(width: 800, height: 600), appearance: .darkAqua, to: "flow_bg_violet_dark.png")

        // 3. Coral Light
        settingsStore.settings.accent = .coral
        let bgCoralLight = FlowBackground()
            .environment(settingsStore)
            .frame(width: 800, height: 600)
        try render(bgCoralLight, size: CGSize(width: 800, height: 600), appearance: .aqua, to: "flow_bg_coral_light.png")

        // 4. Coral Dark
        let bgCoralDark = FlowBackground()
            .environment(settingsStore)
            .frame(width: 800, height: 600)
        try render(bgCoralDark, size: CGSize(width: 800, height: 600), appearance: .darkAqua, to: "flow_bg_coral_dark.png")
    }

    func testRenderReviewAndProcessingViews() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let libraryFile = tempDir.appendingPathComponent("library.json")
        let settingsFile = tempDir.appendingPathComponent("settings.json")
        let libraryStore = LibraryStore(fileURL: libraryFile)
        let settingsStore = SettingsStore(fileURL: settingsFile)
        let pipelineController = PipelineController(libraryStore: libraryStore, settingsStore: settingsStore)

        let bookID = UUID()
        let ch1 = Chapter(
            id: UUID(),
            title: "Kapitel 1: Grundlagen und Physiologie",
            groupTitle: "Teil I: Basiswissen",
            rawText: "Physiologische Grundlagen der Zellbiologie...",
            cleanedText: "Physiologische Grundlagen der Zellbiologie...",
            order: 0,
            audioStatus: .ready,
            audioDurationSeconds: 420
        )
        let ch2 = Chapter(
            id: UUID(),
            title: "Kapitel 2: Klinische Diagnostik",
            groupTitle: "Teil I: Basiswissen",
            rawText: "Methoden der klinischen Untersuchung...",
            cleanedText: "Methoden der klinischen Untersuchung...",
            order: 1,
            audioStatus: .pending
        )
        var book = BookProject(
            id: bookID,
            title: "The Time Machine",
            author: "Stauber, Weissenbacher et al.",
            sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/sample.pdf"),
            chapters: [ch1, ch2],
            mode: .transcription,
            outputFormat: .m4b,
            voice: "martin",
            speechSpeed: 1.0
        )
        book.engineID = .kokoroGerman
        book.status = .needsReview
        libraryStore.upsert(book)

        // Review View Light
        let reviewLight = ReviewView(bookID: bookID)
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 900, height: 800)
        try render(reviewLight, size: CGSize(width: 900, height: 800), appearance: .aqua, to: "review_view_light.png")

        // Review View Dark
        let reviewDark = ReviewView(bookID: bookID)
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 900, height: 800)
        try render(reviewDark, size: CGSize(width: 900, height: 800), appearance: .darkAqua, to: "review_view_dark.png")

        // Processing View Running
        book.status = .processing
        book.currentStage = .synthesizing
        libraryStore.upsert(book)

        let processingRunning = ProcessingView(bookID: bookID)
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 800, height: 700)
        try render(processingRunning, size: CGSize(width: 800, height: 700), appearance: .aqua, to: "processing_view_running.png")

        // Processing View Paused
        book.status = .paused
        book.lastErrorMessage = "Verarbeitung vom Benutzer pausiert"
        libraryStore.upsert(book)

        let processingPaused = ProcessingView(bookID: bookID)
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 800, height: 700)
        try render(processingPaused, size: CGSize(width: 800, height: 700), appearance: .darkAqua, to: "processing_view_paused.png")
    }

    func testRenderSidebarGroupings() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let libraryFile = tempDir.appendingPathComponent("library.json")
        let settingsFile = tempDir.appendingPathComponent("settings.json")
        let libraryStore = LibraryStore(fileURL: libraryFile)
        let settingsStore = SettingsStore(fileURL: settingsFile)
        let pipelineController = PipelineController(libraryStore: libraryStore, settingsStore: settingsStore)

        var b1 = BookProject(
            id: UUID(),
            title: "The Time Machine",
            author: "Stauber, Weissenbacher et al.",
            sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/b1.pdf"),
            chapters: [],
            outputFormat: .m4b,
            voice: "martin",
            speechSpeed: 1.0
        )
        b1.engineID = .kokoroGerman
        var b2 = BookProject(
            id: UUID(),
            title: "Attention Is All You Need",
            author: "Vaswani et al.",
            sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/b2.pdf"),
            chapters: [],
            outputFormat: .m4b,
            voice: "en_heart",
            speechSpeed: 1.0
        )
        b2.documentType = .paper
        b2.topic = "Informatik"
        libraryStore.upsert(b1)
        libraryStore.upsert(b2)

        // 1. Grouping: Topic
        settingsStore.settings.sidebarGrouping = .topic
        let sidebarTopic = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 280, height: 600)
        try render(sidebarTopic, size: CGSize(width: 280, height: 600), appearance: .aqua, to: "sidebar_grouping_topic.png")

        // 2. Grouping: DocumentType
        settingsStore.settings.sidebarGrouping = .documentType
        let sidebarDocType = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 280, height: 600)
        try render(sidebarDocType, size: CGSize(width: 280, height: 600), appearance: .aqua, to: "sidebar_grouping_doctype.png")

        // 3. Grouping: Author
        settingsStore.settings.sidebarGrouping = .author
        let sidebarAuthor = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 280, height: 600)
        try render(sidebarAuthor, size: CGSize(width: 280, height: 600), appearance: .aqua, to: "sidebar_grouping_author.png")

        // 4. Narrow & Wide
        settingsStore.settings.sidebarGrouping = .topic
        let sidebarNarrow = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 240, height: 600)
        try render(sidebarNarrow, size: CGSize(width: 240, height: 600), appearance: .aqua, to: "sidebar_narrow_240.png")

        let sidebarWide = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .frame(width: 400, height: 600)
        try render(sidebarWide, size: CGSize(width: 400, height: 600), appearance: .aqua, to: "sidebar_wide_400.png")
    }

    func testRenderPlayerWithAmbientModes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let libraryFile = tempDir.appendingPathComponent("library.json")
        let settingsFile = tempDir.appendingPathComponent("settings.json")
        let libraryStore = LibraryStore(fileURL: libraryFile)
        let settingsStore = SettingsStore(fileURL: settingsFile)
        let pipelineController = PipelineController(libraryStore: libraryStore, settingsStore: settingsStore)

        // Use sample audio from repo
        let sampleAudioURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs")
            .appendingPathComponent("hoerproben")
            .appendingPathComponent("kokoro-de-martin.wav")

        let bookID = UUID()
        let ch1 = Chapter(
            id: UUID(),
            title: "Kapitel 1: Der Bau des Zellteilung",
            groupTitle: "Zellbiologie",
            rawText: "Text...",
            cleanedText: "Text...",
            order: 0,
            audioStatus: .ready,
            audioFileURL: sampleAudioURL,
            audioDurationSeconds: 120
        )
        let bookmark = (try? sampleAudioURL.bookmarkData()) ?? Data()
        var book = BookProject(
            id: bookID,
            title: "The Time Machine",
            author: "Stauber, Weissenbacher et al.",
            sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/sample.pdf"),
            chapters: [ch1],
            outputFormat: .m4b,
            voice: "martin",
            speechSpeed: 1.0
        )
        book.engineID = .kokoroGerman
        book.status = .completed
        book.packagedAudio = PackagedAudioInfo(
            url: sampleAudioURL,
            bookmarkData: bookmark,
            sizeBytes: 1794044,
            verifiedAt: Date()
        )
        libraryStore.upsert(book)

        // 1. Ambient Off
        book.ambientSound = nil
        libraryStore.upsert(book)
        let playerOff = PlayerView(bookID: bookID)
            .environment(libraryStore)
            .environment(pipelineController)
            .environment(settingsStore)
            .frame(width: 950, height: 650)
        try render(playerOff, size: CGSize(width: 950, height: 650), appearance: .aqua, to: "player_ambient_off.png")

        // 2. Ambient Fire
        book.ambientSound = "fire"
        book.ambientVolumePercent = 25
        libraryStore.upsert(book)
        let playerFire = PlayerView(bookID: bookID)
            .environment(libraryStore)
            .environment(pipelineController)
            .environment(settingsStore)
            .frame(width: 950, height: 650)
        try render(playerFire, size: CGSize(width: 950, height: 650), appearance: .aqua, to: "player_ambient_fire.png")

        // 3. Ambient Rain
        book.ambientSound = "rain"
        book.ambientVolumePercent = 20
        libraryStore.upsert(book)
        let playerRain = PlayerView(bookID: bookID)
            .environment(libraryStore)
            .environment(pipelineController)
            .environment(settingsStore)
            .frame(width: 950, height: 650)
        try render(playerRain, size: CGSize(width: 950, height: 650), appearance: .darkAqua, to: "player_ambient_rain.png")

        // 4. Ambient Water
        book.ambientSound = "water"
        book.ambientVolumePercent = 20
        libraryStore.upsert(book)
        let playerWater = PlayerView(bookID: bookID)
            .environment(libraryStore)
            .environment(pipelineController)
            .environment(settingsStore)
            .frame(width: 950, height: 650)
        try render(playerWater, size: CGSize(width: 950, height: 650), appearance: .aqua, to: "player_ambient_water.png")
    }

    func testRenderImportDropZone() throws {
        let settingsStore = SettingsStore()
        let dropZoneLight = ImportDropZone(onImport: { _ in })
            .environment(settingsStore)
            .frame(width: 800, height: 600)
        try render(dropZoneLight, size: CGSize(width: 800, height: 600), appearance: .aqua, to: "import_dropzone_light.png")

        let dropZoneDark = ImportDropZone(onImport: { _ in })
            .environment(settingsStore)
            .frame(width: 800, height: 600)
        try render(dropZoneDark, size: CGSize(width: 800, height: 600), appearance: .darkAqua, to: "import_dropzone_dark.png")
    }

    func testRenderSettingsNarrowClipping() throws {
        let settingsStore = SettingsStore()
        settingsStore.settings.appearanceMode = .light
        let narrow = ScrollView {
            PillSection("Erscheinungsbild") {
                AppearanceSettingsSection()
            }
            .padding(16)
        }
        .environment(settingsStore)
        .frame(width: 480, height: 600)
        try render(narrow, size: CGSize(width: 480, height: 600), appearance: .aqua, to: "settings_appearance_narrow_clipped.png")
    }
}
