import XCTest
import SwiftUI
import AppKit
@testable import AudiobookForge

@MainActor
final class VisualAuditSnapshotTests: XCTestCase {
    private var outputDir: URL {
        if let custom = ProcessInfo.processInfo.environment["AUDIOBOOKFORGE_SNAPSHOT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookForge-Snapshots", isDirectory: true)
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

        let isJPEG = filename.lowercased().hasSuffix(".jpg") || filename.lowercased().hasSuffix(".jpeg")
        let imgData = isJPEG
            ? bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            : bitmapRep.representation(using: .png, properties: [:])
        guard let imgData else {
            XCTFail("Could not create image data for \(filename)")
            return
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let fileURL = outputDir.appendingPathComponent(filename)
        try imgData.write(to: fileURL)
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
            title: "Distributed Systems: Principles and Paradigms",
            author: "A. S. Tanenbaum, M. van Steen",
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
        let playback = PlaybackSession()

        var b1 = BookProject(
            id: UUID(),
            title: "Distributed Systems: Principles and Paradigms",
            author: "A. S. Tanenbaum, M. van Steen",
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
            .environment(playback)
            .frame(width: 280, height: 600)
        try render(sidebarTopic, size: CGSize(width: 280, height: 600), appearance: .aqua, to: "sidebar_grouping_topic.png")

        // 2. Grouping: DocumentType
        settingsStore.settings.sidebarGrouping = .documentType
        let sidebarDocType = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .environment(playback)
            .frame(width: 280, height: 600)
        try render(sidebarDocType, size: CGSize(width: 280, height: 600), appearance: .aqua, to: "sidebar_grouping_doctype.png")

        // 3. Grouping: Author
        settingsStore.settings.sidebarGrouping = .author
        let sidebarAuthor = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .environment(playback)
            .frame(width: 280, height: 600)
        try render(sidebarAuthor, size: CGSize(width: 280, height: 600), appearance: .aqua, to: "sidebar_grouping_author.png")

        // 4. Narrow & Wide
        settingsStore.settings.sidebarGrouping = .topic
        let sidebarNarrow = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .environment(playback)
            .frame(width: 240, height: 600)
        try render(sidebarNarrow, size: CGSize(width: 240, height: 600), appearance: .aqua, to: "sidebar_narrow_240.png")

        let sidebarWide = SidebarView(selection: .constant(nil), onImport: { _ in })
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .environment(playback)
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
        let playback = PlaybackSession()

        // Use bundled voice sample from repo
        let sampleAudioURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudiobookForge")
            .appendingPathComponent("Resources")
            .appendingPathComponent("VoiceSamples")
            .appendingPathComponent("sample_kokoro_de_martin.m4a")

        let bookID = UUID()
        let ch1 = Chapter(
            id: UUID(),
            title: "Kapitel 1: Einführung in verteilte Systeme",
            groupTitle: "Grundlagen",
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
            title: "Distributed Systems: Principles and Paradigms",
            author: "A. S. Tanenbaum, M. van Steen",
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
            .environment(playback)
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
            .environment(playback)
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
            .environment(playback)
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
            .environment(playback)
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

    func testRenderReadmeEnglishScreenshots() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let libraryStore = LibraryStore(fileURL: tempDir.appendingPathComponent("library.json"))
        let settingsStore = SettingsStore(fileURL: tempDir.appendingPathComponent("settings.json"))
        settingsStore.settings.appearanceMode = .dark
        settingsStore.settings.appLanguage = .en
        settingsStore.settings.accent = .violet
        settingsStore.settings.omlxBaseURL = "http://127.0.0.1:8000/v1"
        settingsStore.settings.omlxModel = "Qwen3-30B-A3B-MLX-4bit"
        let pipelineController = PipelineController(libraryStore: libraryStore, settingsStore: settingsStore)
        let playback = PlaybackSession()
        let fun = FunCenter()

        let sampleAudioURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudiobookForge")
            .appendingPathComponent("Resources")
            .appendingPathComponent("VoiceSamples")
            .appendingPathComponent("sample_kokoro_af_heart.m4a")
        let bookmark = (try? sampleAudioURL.bookmarkData()) ?? Data()

        let tmCh1 = Chapter(
            id: UUID(),
            title: "Chapter I — Introduction",
            groupTitle: "Part I: The Time Traveller",
            rawText: "The Time Traveller (for so it will be convenient to speak of him) was expounding a recondite matter to us. His pale grey eyes shone and twinkled, and his usually pale face was flushed and animated. The fire burned brightly, and the soft radiance of the incandescent lights in the lilies of silver caught the bubbles that flashed and passed in our glasses.",
            cleanedText: "The Time Traveller (for so it will be convenient to speak of him) was expounding a recondite matter to us. His pale grey eyes shone and twinkled, and his usually pale face was flushed and animated. The fire burned brightly, and the soft radiance of the incandescent lights in the lilies of silver caught the bubbles that flashed and passed in our glasses.",
            summarizedText: "The Time Traveller gathers his guests around a bright fireplace to explain how duration is the fourth dimension of space.",
            order: 0,
            audioStatus: .ready,
            audioFileURL: sampleAudioURL,
            audioDurationSeconds: 1120
        )
        let tmCh2 = Chapter(
            id: UUID(),
            title: "Chapter II — The Machine",
            groupTitle: "Part I: The Time Traveller",
            rawText: "The thing the Time Traveller held in his hand was a glittering metallic framework, scarcely larger than a small clock, and very delicately made. There was ivory in it, and some transparent crystalline substance.",
            cleanedText: "The thing the Time Traveller held in his hand was a glittering metallic framework, scarcely larger than a small clock, and very delicately made. There was ivory in it, and some transparent crystalline substance.",
            summarizedText: "He demonstrates a miniature brass and quartz prototype of the Time Machine on the parlour table.",
            order: 1,
            audioStatus: .ready,
            audioFileURL: sampleAudioURL,
            audioDurationSeconds: 980
        )
        let tmCh3 = Chapter(
            id: UUID(),
            title: "Chapter III — The Time Traveller Returns",
            groupTitle: "Part II: The Year 802,701",
            rawText: "I think that at that time none of us quite believed in the Time Machine. The fact is, the Time Traveller was one of those men who are too clever to be believed.",
            cleanedText: "I think that at that time none of us quite believed in the Time Machine. The fact is, the Time Traveller was one of those men who are too clever to be believed.",
            order: 2,
            audioStatus: .ready,
            audioFileURL: sampleAudioURL,
            audioDurationSeconds: 1340
        )
        var timeMachine = BookProject(
            id: UUID(),
            title: "The Time Machine",
            author: "H. G. Wells",
            sourceType: .epub,
            sourceURL: URL(fileURLWithPath: "/tmp/The_Time_Machine.epub"),
            chapters: [tmCh1, tmCh2, tmCh3],
            mode: .transcription,
            outputFormat: .m4b,
            voice: "en/Freya",
            speechSpeed: 1.0
        )
        timeMachine.engineID = .phonon
        timeMachine.status = .completed
        timeMachine.detectedLanguageCode = "en"
        timeMachine.topic = "literature"
        timeMachine.topicOverride = "literature"
        timeMachine.packagedAudio = PackagedAudioInfo(url: sampleAudioURL, bookmarkData: bookmark, sizeBytes: 48_200_000, verifiedAt: Date())

        var christmasCarol = BookProject(
            id: UUID(),
            title: "A Christmas Carol",
            author: "Charles Dickens",
            sourceType: .epub,
            sourceURL: URL(fileURLWithPath: "/tmp/A_Christmas_Carol.epub"),
            chapters: [
                Chapter(id: UUID(), title: "Stave I: Marley's Ghost", rawText: "Marley was dead: to begin with.", cleanedText: "Marley was dead: to begin with.", order: 0, audioStatus: .ready, audioDurationSeconds: 2100),
                Chapter(id: UUID(), title: "Stave II: The First of the Three Spirits", rawText: "When Scrooge awoke, it was so dark...", cleanedText: "When Scrooge awoke, it was so dark...", order: 1, audioStatus: .ready, audioDurationSeconds: 2340)
            ],
            mode: .transcription,
            outputFormat: .m4b,
            voice: "en/george",
            speechSpeed: 1.0
        )
        christmasCarol.engineID = .pocketTTS
        christmasCarol.status = .completed
        christmasCarol.detectedLanguageCode = "en"
        christmasCarol.topic = "literature"
        christmasCarol.topicOverride = "literature"
        christmasCarol.packagedAudio = PackagedAudioInfo(url: sampleAudioURL, bookmarkData: bookmark, sizeBytes: 64_100_000, verifiedAt: Date())

        let dsCh1 = Chapter(
            id: UUID(),
            title: "1. Reliable, Scalable, and Maintainable Systems",
            groupTitle: "Part I: Foundations of Data Systems",
            rawText: "Many applications today are data-intensive, as opposed to compute-intensive. Raw CPU power is rarely a limiting factor for these applications — bigger problems are usually the amount of data, the complexity of data, and the speed at which it is changing.",
            cleanedText: "Many applications today are data-intensive, as opposed to compute-intensive. Raw CPU power is rarely a limiting factor for these applications — bigger problems are usually the amount of data, the complexity of data, and the speed at which it is changing.",
            summarizedText: "Data-intensive architectures prioritize reliability against hardware and human faults, scalability under growing load, and long-term maintainability.",
            order: 0,
            audioStatus: .ready,
            audioDurationSeconds: 840
        )
        let dsCh2 = Chapter(
            id: UUID(),
            title: "2. Data Models and Query Languages",
            groupTitle: "Part I: Foundations of Data Systems",
            rawText: "Data models are perhaps the most important part of developing software, because they have such a profound effect: not only on how the software is written, but also on how we think about the problem that we are solving.",
            cleanedText: "Data models are perhaps the most important part of developing software, because they have such a profound effect: not only on how the software is written, but also on how we think about the problem that we are solving.",
            order: 1,
            audioStatus: .pending
        )
        let dsCh3 = Chapter(
            id: UUID(),
            title: "3. Storage and Retrieval: B-Trees and LSM-Trees",
            groupTitle: "Part I: Foundations of Data Systems",
            rawText: "On the most fundamental level, a database needs to do two things: when you give it some data, it should store the data, and when you ask it again later, it should give the data back to you.",
            cleanedText: "On the most fundamental level, a database needs to do two things: when you give it some data, it should store the data, and when you ask it again later, it should give the data back to you.",
            order: 2,
            audioStatus: .pending
        )
        let dsCh4 = Chapter(
            id: UUID(),
            title: "5. Replication and Consensus",
            groupTitle: "Part II: Distributed Data",
            rawText: "Replication means keeping a copy of the same data on multiple machines that are connected via a network.",
            cleanedText: "Replication means keeping a copy of the same data on multiple machines that are connected via a network.",
            order: 3,
            audioStatus: .pending
        )
        var dataSystems = BookProject(
            id: UUID(),
            title: "Designing Data-Intensive Systems",
            author: "M. Kleppmann",
            sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/Data_Intensive_Systems.pdf"),
            chapters: [dsCh1, dsCh2, dsCh3, dsCh4],
            mode: .summary,
            outputFormat: .m4b,
            voice: "af_heart",
            speechSpeed: 1.0
        )
        dataSystems.engineID = .kokoro
        dataSystems.documentType = .book
        dataSystems.detectedLanguageCode = "en"
        dataSystems.topic = "science"
        dataSystems.topicOverride = "science"
        dataSystems.status = .needsReview

        var attentionPaper = BookProject(
            id: UUID(),
            title: "Attention Is All You Need",
            author: "Vaswani et al.",
            sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/tmp/Attention_Is_All_You_Need.pdf"),
            chapters: [
                Chapter(id: UUID(), title: "1. Introduction & Background", rawText: "Recurrent neural networks...", cleanedText: "Recurrent neural networks...", order: 0, audioStatus: .ready, audioDurationSeconds: 510),
                Chapter(id: UUID(), title: "3. Model Architecture — Multi-Head Attention", rawText: "Most competitive neural sequence transduction models...", cleanedText: "Most competitive neural sequence transduction models...", order: 1, audioStatus: .ready, audioDurationSeconds: 690)
            ],
            mode: .summary,
            outputFormat: .m4b,
            voice: "af_heart",
            speechSpeed: 1.0
        )
        attentionPaper.engineID = .kokoro
        attentionPaper.documentType = .paper
        attentionPaper.detectedLanguageCode = "en"
        attentionPaper.topic = "science"
        attentionPaper.topicOverride = "science"
        attentionPaper.status = .completed
        attentionPaper.packagedAudio = PackagedAudioInfo(url: sampleAudioURL, bookmarkData: bookmark, sizeBytes: 18_400_000, verifiedAt: Date())

        libraryStore.upsert(timeMachine)
        libraryStore.upsert(christmasCarol)
        libraryStore.upsert(dataSystems)
        libraryStore.upsert(attentionPaper)

        let windowSize = CGSize(width: 1280, height: 820)

        func studioFrame<Content: View>(selection: SidebarSelection, ambientScene: AmbientSound? = nil, @ViewBuilder content: () -> Content) -> some View {
            ZStack {
                FlowBackground()
                if let ambientScene {
                    PixelSceneView(scene: ambientScene, intensity: 0.65, animated: false, contentOffsetX: 0, lastFlash: nil)
                        .ignoresSafeArea()
                }
                HStack(spacing: 0) {
                    SidebarView(selection: .constant(selection), importingFiles: [], onImport: { _ in })
                        .frame(width: 280)
                    content()
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .environment(libraryStore)
            .environment(settingsStore)
            .environment(pipelineController)
            .environment(playback)
            .environment(fun)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, .dark)
            .environment(\.flowAccent, .violet)
            .frame(width: windowSize.width, height: windowSize.height)
        }

        // 1. overview.jpg — Main Library / Bookshelf view in English
        let overviewView = studioFrame(selection: .home) {
            LibraryHomeView(selection: .constant(.home), importingFiles: [], onImport: { _ in })
        }
        try render(overviewView, size: windowSize, appearance: .darkAqua, to: "overview.jpg")

        // 2. voices.jpg — Voice Gallery & TTS Engines in English
        let voicesView = studioFrame(selection: .settings(.voices)) {
            VoiceGalleryView(languageCode: "en")
                .background { PaperPage() }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .padding(.top, 4)
        }
        try render(voicesView, size: windowSize, appearance: .darkAqua, to: "voices.jpg")

        // 3. pipeline.jpg — Chapter Review & AI Summarization / Conversion Pipeline
        let pipelineView = studioFrame(selection: .book(dataSystems.id)) {
            ReviewView(bookID: dataSystems.id)
        }
        try render(pipelineView, size: windowSize, appearance: .darkAqua, to: "pipeline.jpg")

        // 4. player.jpg — Now Playing with Fireplace Ambient Soundscape
        UserDefaults.standard.set(true, forKey: "player.showChapters")
        UserDefaults.standard.set(false, forKey: "player.showText")
        var tmAmbient = timeMachine
        tmAmbient.ambientSound = "fire"
        tmAmbient.ambientVolumePercent = 30
        libraryStore.upsert(tmAmbient)
        playback.ambient.select(.fire, bookIsPlaying: false)
        let playerView = studioFrame(selection: .book(tmAmbient.id), ambientScene: .fire) {
            PlayerView(bookID: tmAmbient.id)
        }
        try render(playerView, size: windowSize, appearance: .darkAqua, to: "player.jpg")

        // 5. settings.jpg — Appearance & Flow Design Settings in English
        let settingsView = studioFrame(selection: .settings(.appearance)) {
            SettingsView(pane: .appearance)
        }
        try render(settingsView, size: windowSize, appearance: .darkAqua, to: "settings.jpg")
    }
}
