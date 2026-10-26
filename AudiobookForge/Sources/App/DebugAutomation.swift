#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit

/// DEBUG-only automation for visual review: another process posts a
/// distributed notification `ABFDebugCommand` and the app navigates or
/// photographs its own window (ScreenCaptureKit — glass and materials are
/// captured exactly as on screen, unlike offscreen rendering).
///
/// userInfo keys:
/// - `nav`: "home" | "settings:<pane>" | "book:<uuid>" | "book-index:<n>"
/// - `preset`: "listen" | "read" | "study"
/// - `ambient`: scene raw value or "off"
/// - `appearance`: "light" | "dark" | "system"
/// - `snapshot`: absolute PNG path
/// - `size`: "WIDTHxHEIGHT" window content size
@MainActor
enum DebugAutomation {
    static let navigate = Notification.Name("ABFDebugNavigate")
    private static var observer: NSObjectProtocol?

    static func install() {
        // Never inside the unit-test host (no prompts, no observers there).
        guard observer == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Registers the debug build in System Settings → Screen Recording
        // and shows the system prompt once.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ABFDebugCommand"), object: nil, queue: .main
        ) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { handle(info) }
        }
    }

    private static func handle(_ info: [String: String]) {
        if let size = info["size"], let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
            }
        }
        NotificationCenter.default.post(name: navigate, object: nil, userInfo: info)
        if let path = info["snapshot"] {
            Task {
                try? await Task.sleep(for: .milliseconds(Int(info["delay"] ?? "900") ?? 900))
                await snapshot(to: path)
            }
        }
    }

    static func snapshot(to path: String) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.frame.width > 300 }) else {
                try? "no window".write(toFile: path + ".err", atomically: true, encoding: .utf8)
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: path))
            }
        } catch {
            try? "\(error)".write(toFile: path + ".err", atomically: true, encoding: .utf8)
        }
    }
}

/// Applies navigation commands to the root view's state.
struct DebugAutomationReceiver: ViewModifier {
    /// "id:<uuid>" addresses a book exactly, anything else matches the title.
    static func matches(_ book: BookProject, _ query: String) -> Bool {
        query.hasPrefix("id:") ? book.id.uuidString == String(query.dropFirst(3)) : book.title.localizedCaseInsensitiveContains(query)
    }

    @Binding var selection: SidebarSelection?
    var importDocuments: ([URL]) -> Void
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PlaybackSession.self) private var playback
    @Environment(PipelineController.self) private var pipelineController

    func body(content: Content) -> some View {
        content
            .onAppear { DebugAutomation.install() }
            .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
                let info = note.userInfo as? [String: String] ?? [:]
                if let power = info["power"], let mode = PowerMode(rawValue: power) {
                    settingsStore.settings.powerModeOnAdapter = mode
                }
                if let value = info["phononEnglish31m"] { settingsStore.settings.phononEnglish31m = value == "1" }
                // Visual pass v4.3: pixel=1|0 (no achievement), workshop=<title>:<ready>
                // shows a test book paused with <ready> chapters done.
                if let value = info["pixel"] { settingsStore.settings.pixelMode = value == "1" }
                if let spec = info["workshop"], let colon = spec.lastIndex(of: ":"), let ready = Int(spec[spec.index(after: colon)...]),
                   var book = libraryStore.books.first(where: { Self.matches($0, String(spec[..<colon])) }) {
                    let ids = book.sortedChapters.map(\.id)
                    for (index, id) in ids.enumerated() {
                        if let real = book.chapters.firstIndex(where: { $0.id == id }) {
                            book.chapters[real].audioStatus = index < ready ? .ready : (index < ready + 3 ? .synthesizing : .pending)
                        }
                    }
                    book.status = .paused
                    libraryStore.upsert(book)
                    selection = .book(book.id)
                }
                if let appearance = info["appearance"], let mode = AppearanceMode(rawValue: appearance) {
                    settingsStore.settings.appearanceMode = mode
                }
                if let nav = info["nav"] {
                    if nav == "home" {
                        selection = .home
                    } else if nav.hasPrefix("settings:"), let pane = SettingsPane(rawValue: String(nav.dropFirst(9))) {
                        selection = .settings(pane)
                    } else if nav.hasPrefix("book:"), let id = UUID(uuidString: String(nav.dropFirst(5))) {
                        selection = .book(id)
                    } else if nav.hasPrefix("book-index:"), let index = Int(nav.dropFirst(11)) {
                        let books = libraryStore.books.sorted { $0.createdAt > $1.createdAt }
                        if books.indices.contains(index) { selection = .book(books[index].id) }
                    }
                }
                if let preset = info["preset"] {
                    let panes: (Bool, Bool) = preset == "listen" ? (false, false) : preset == "read" ? (false, true) : (true, true)
                    UserDefaults.standard.set(panes.0, forKey: "player.showChapters")
                    UserDefaults.standard.set(panes.1, forKey: "player.showText")
                }
                if let ambient = info["ambient"] {
                    playback.ambient.select(AmbientSound(rawValue: ambient), bookIsPlaying: playback.coordinator.isPlaying)
                }
                if let title = info["enqueue"], let book = libraryStore.books.first(where: { Self.matches($0, title) }) {
                    pipelineController.enqueue(bookID: book.id)
                    selection = .book(book.id)
                }
                // Repair/tests: regenerate one chapter (by order) like the player menu.
                if let query = info["regenBook"], let orderText = info["chapter"], let order = Int(orderText),
                   let book = libraryStore.book(id: libraryStore.books.first(where: { Self.matches($0, query) })?.id ?? UUID()),
                   let chapter = book.chapters.first(where: { $0.order == order }) {
                    pipelineController.regenerateChapter(bookID: book.id, chapterID: chapter.id)
                }
                // Test cleanup: remove a book the same way the sidebar does.
                if let query = info["removeBook"], let book = libraryStore.books.first(where: { Self.matches($0, query) }) {
                    pipelineController.cancelProcessing(bookID: book.id)
                    if playback.bookID == book.id { playback.close() }
                    libraryStore.remove(book)
                    ChapterAudioStore.removeChapterAudio(bookID: book.id)
                }
                if let query = info["renameBook"], let title = info["title"],
                   var book = libraryStore.book(id: libraryStore.books.first(where: { Self.matches($0, query) })?.id ?? UUID()) {
                    book.title = title
                    libraryStore.upsert(book)
                }
                // Voice-cloning test: register a reference clip as a clone.
                if let audio = info["cloneAudio"] {
                    _ = try? VoiceCloneStore.shared.add(name: info["cloneName"] ?? "Test", refText: info["cloneText"] ?? "",
                                                        languageCode: info["cloneLang"] ?? "en", audioURL: URL(fileURLWithPath: audio))
                }
                // Engine tests: set engine/voice of a book ("engineBook" = title part).
                if let title = info["engineBook"], let engineRaw = info["engine"], let engine = TTSEngineID(rawValue: engineRaw),
                   var book = libraryStore.book(id: libraryStore.books.first(where: { Self.matches($0, title) })?.id ?? UUID()) {
                    book.engineID = engine
                    if let voice = info["voice"] {
                        // "clone:latest" → the newest registered clone.
                        book.voice = voice == "clone:latest"
                            ? (VoiceCloneStore.shared.clones().max { $0.createdAt < $1.createdAt }.map { "clone:\($0.id.uuidString)" } ?? voice)
                            : voice
                    }
                    libraryStore.upsert(book)
                }
                // v4: re-voice a finished book ("revoiceBook" = title part).
                if let title = info["revoiceBook"], let engineRaw = info["engine"], let engine = TTSEngineID(rawValue: engineRaw),
                   let voice = info["voice"], let book = libraryStore.books.first(where: { Self.matches($0, title) }) {
                    pipelineController.revoice(bookID: book.id, engine: engine, voice: voice, speed: Double(info["speed"] ?? "1") ?? 1,
                                               resummarize: info["resummarize"] == "1")
                }
                if let title = info["revoiceSheet"], let book = libraryStore.books.first(where: { Self.matches($0, title) }) {
                    NotificationCenter.default.post(name: .openRevoice, object: book.id)
                }
                if info["revoiceSheet"] == "close" {
                    for window in NSApp.windows { window.sheets.reversed().forEach { window.endSheet($0) } }
                }
                // v4: link a book to its moved M4B and free the chapter cache.
                if let title = info["relinkBook"], let file = info["file"],
                   let book = libraryStore.book(id: libraryStore.books.first(where: { Self.matches($0, title) })?.id ?? UUID()) {
                    Task {
                        guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settingsStore.settings),
                              let result = await ChapterAudioCleanup.releaseChapterAudio(book: book, packagedURL: URL(fileURLWithPath: file), ffmpeg: ffmpeg,
                                                                                         chapterAudioRoot: AppPaths.chapterAudioRoot) else {
                            try? "relink: nicht möglich".write(toFile: "/tmp/abf-relink.log", atomically: true, encoding: .utf8); return
                        }
                        if result.verified { libraryStore.upsert(result.book); libraryStore.flush() }
                        try? result.messages.joined(separator: "\n").write(toFile: "/tmp/abf-relink.log", atomically: true, encoding: .utf8)
                    }
                }
                if let language = info["prepareNeural"] {
                    Task {
                        let result: String
                        do { try await PhononEnvironmentManager.shared.prepareNeuralEngine(language) { _ in }; result = "ok" }
                        catch { result = error.localizedDescription }
                        try? result.write(toFile: "/tmp/abf-neural.log", atomically: true, encoding: .utf8)
                    }
                }
                // v4.2: the gallery's install path, end to end:
                // installVoice=<engine>:<voice> [removeAfter=1] → /tmp/abf-install.log
                if let spec = info["installVoice"], let colon = spec.firstIndex(of: ":"),
                   let engine = TTSEngineID(rawValue: String(spec[..<colon])) {
                    let voice = VoiceID(engine: engine, voice: String(spec[spec.index(after: colon)...]))
                    let settings = settingsStore.settings
                    let removeAfter = info["removeAfter"] == "1"
                    Task { @MainActor in
                        var log: [String] = []
                        let missing = await Task.detached { EngineInventory.missingComponents(for: voice, settings: settings) }.value
                        log.append("MISSING " + missing.map(\.id).joined(separator: ","))
                        do {
                            try await ComponentRunner.install(missing) { index, text in
                                if text.hasPrefix(L("Lädt")) == false { log.append("STEP \(index) \(text)") }
                            }
                            let after = await Task.detached { EngineInventory.missingComponents(for: voice, settings: settings) }.value
                            log.append("AFTER " + (after.isEmpty ? "complete" : after.map(\.id).joined(separator: ",")))
                            if removeAfter {
                                for component in missing.reversed() where component.kind != .runtime {
                                    let fresh = await Task.detached { EngineInventory.status(of: engine, settings: settings).components.first { $0.id == component.id } }.value
                                    if let fresh { try await ComponentRunner.remove(fresh) }
                                }
                                let removed = await Task.detached { EngineInventory.missingComponents(for: voice, settings: settings) }.value
                                log.append("REMOVED " + removed.map(\.id).joined(separator: ","))
                            }
                            log.append("DONE")
                        } catch {
                            log.append("ERROR \(error.localizedDescription)")
                        }
                        try? log.joined(separator: "\n").write(toFile: "/tmp/abf-install.log", atomically: true, encoding: .utf8)
                    }
                }
                // neuralSpeak=<model>:<voice> → /tmp/abf-neural-speak.log (samples, seconds)
                if let spec = info["neuralSpeak"], let colon = spec.firstIndex(of: ":") {
                    let model = String(spec[..<colon]), voice = String(spec[spec.index(after: colon)...])
                    Task {
                        let samples = LockedBox(0)
                        let start = Date()
                        var result: String
                        do {
                            try await PhononNeuralEngine.shared.synthesize(
                                segments: ["This is a short test of the smaller model on the Neural Engine."], voice: voice,
                                language: PhononEnvironmentManager.language(ofModel: model),
                                directory: PhononEnvironmentManager.shared.neuralDirectory(for: model)
                            ) { _, chunk in samples.withLock { $0 += chunk.count } }
                            result = String(format: "samples %d audio %.2fs took %.2fs", samples.withLock { $0 }, Double(samples.withLock { $0 }) / 24000, Date().timeIntervalSince(start))
                        } catch { result = "ERROR \(error.localizedDescription)" }
                        try? result.write(toFile: "/tmp/abf-neural-speak.log", atomically: true, encoding: .utf8)
                    }
                }
                // windowInfo=1 → /tmp/abf-windows.log: every window and sheet,
                // its size and whether the user can resize it.
                // sheetSize=WxH: resizes the open sheet like a drag on its edge.
                if let size = info["sheetSize"], let sheet = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }) {
                    let parts = size.split(separator: "x").compactMap { Double($0) }
                    if parts.count == 2 { sheet.setContentSize(NSSize(width: parts[0], height: parts[1])) }
                }
                if info["windowInfo"] != nil {
                    let lines = NSApp.windows.filter(\.isVisible).map { window in
                        String(format: "%@ sheet=%d resizable=%d size=%.0fx%.0f min=%.0fx%.0f max=%.0fx%.0f",
                               window.className, window.isSheet ? 1 : 0, window.styleMask.contains(.resizable) ? 1 : 0,
                               window.frame.width, window.frame.height, window.minSize.width, window.minSize.height,
                               window.maxSize.width, window.maxSize.height)
                    }
                    try? lines.joined(separator: "\n").write(toFile: "/tmp/abf-windows.log", atomically: true, encoding: .utf8)
                }
                if let dir = info["buildSamples"] {
                    let settings = settingsStore.settings
                    let only = info["engines"].map { Set($0.split(separator: ",").compactMap { TTSEngineID(rawValue: String($0)) }) }
                    Task.detached { await VoiceSampleBuilder.build(into: URL(fileURLWithPath: dir), settings: settings, only: only) }
                }
                if let title = info["open"], let book = libraryStore.books.first(where: { Self.matches($0, title) }) {
                    selection = .book(book.id)
                }
                if let path = info["import"] {
                    importDocuments(path.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
                }
                if info["setup"] == "open" {
                    NotificationCenter.default.post(name: .openSetupAssistant, object: nil)
                }
                if info["play"] == "toggle" {
                    playback.coordinator.togglePlayPause()
                }
            }
    }
}
#endif
