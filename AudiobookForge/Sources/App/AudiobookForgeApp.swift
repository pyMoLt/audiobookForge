import SwiftUI

@main
struct AudiobookForgeApp: App {
    @State private var libraryStore = LibraryStore()
    @State private var settingsStore = SettingsStore()
    @State private var pipelineController: PipelineController
    @State private var playback = PlaybackSession()

    init() {
        // A dying bridge/ffmpeg child used to kill the whole app: writing
        // to the closed stdin pipe delivered SIGPIPE (default action =
        // terminate). Ignore it — pipe writes then surface as EPIPE
        // errors, which the streaming code already handles.
        signal(SIGPIPE, SIG_IGN)

        // One-time v2 → v3 library migration (plan 5.1): backed up first,
        // atomic per book, rolled back to the untouched v2 file on any
        // failure (the store then keeps running in v2 mode and shows a
        // banner). NEVER under XCTest: unit tests run inside this app as
        // their host process and must not touch the developer's real
        // library.
        var migrationFailure: String?
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            switch LibraryMigrator.migrateIfNeeded(root: AppPaths.applicationSupportDirectory) {
            case .failed(let message):
                migrationFailure = "Bibliotheksumstellung (v2 → v3) fehlgeschlagen — die App läuft mit den unveränderten v2-Daten weiter. \(message)"
            default:
                break
            }
        }

        let library = LibraryStore()
        if let migrationFailure {
            library.migrationNotice = migrationFailure
        }
        let settings = SettingsStore()
        CoverColorCache.libraryRoot = library.rootURL
        _libraryStore = State(initialValue: library)
        _settingsStore = State(initialValue: settings)
        _pipelineController = State(initialValue: PipelineController(libraryStore: library, settingsStore: settings))

        // Housekeeping at launch: delete chapter audio of books that no
        // longer exist, then migrate any leftover uncompressed chapter WAVs
        // from the old pipeline to the compressed chapter format (and
        // delete the WAVs). Both run in the background; the library is
        // only touched via upserts on the main actor.
        //
        // NEVER when running under XCTest: unit tests run inside this app
        // as their host process, and housekeeping against the developer's
        // REAL library is destructive from a test context.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            let books = library.books
            Task { @MainActor in
                ChapterAudioStore.removeOrphanChapterAudio(keeping: books.map(\.id))
                await ChapterAudioStore.migrateLegacyChapterAudio(libraryStore: library, settings: settings.settings)
                if let ffmpeg = await FFmpegLocator.resolveAsync(settings: settings.settings) {
                    await ChapterAudioCleanup.cleanupVerifiedPackagedBooks(
                        libraryStore: library,
                        ffmpeg: ffmpeg,
                        chapterAudioRoot: AppPaths.chapterAudioRoot
                    )
                }
                AppPaths.cleanupOrphanedTempFiles()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryStore)
                .environment(settingsStore)
                .environment(pipelineController)
                .environment(playback)
                // Small enough to keep the player beside other work (v3.2); the
                // sidebar folds away by itself below 760 pt.
                .frame(minWidth: 440, minHeight: 380)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                ImportCommand()
            }
            CommandGroup(replacing: .appSettings) {
                NavigateCommand(title: "Einstellungen …", target: .settings(.voices))
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Wiedergabe") {
                PlaybackCommands(playback: playback, coordinator: playback.coordinator)
            }
            CommandGroup(after: .windowArrangement) {
                AlwaysOnTopMenuCommand()
            }
        }
    }
}

private struct NavigateCommand: View {
    let title: String
    let target: SidebarSelection
    @FocusedValue(\.navigateTo) private var navigate

    var body: some View {
        Button(title) { navigate?(target) }
            .disabled(navigate == nil)
    }
}

private struct ImportCommand: View {
    @FocusedValue(\.importDocuments) private var importDocuments

    var body: some View {
        Button("Buch importieren …") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf, .epubDocument]
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { importDocuments?(panel.urls) }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(importDocuments == nil)
    }
}

/// Menu + shortcuts for the global player (work from any screen).
private struct PlaybackCommands: View {
    let playback: PlaybackSession
    @ObservedObject var coordinator: AudioPlayerCoordinator

    var body: some View {
        let hasBook = playback.bookID != nil && coordinator.hasSource
        Button(coordinator.isPlaying ? "Pause" : "Wiedergabe") { coordinator.togglePlayPause() }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!hasBook)
        Divider()
        Button("15 Sekunden zurück") { coordinator.skip(by: -15) }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!hasBook)
        Button("30 Sekunden vor") { coordinator.skip(by: 30) }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!hasBook)
        Button("Vorheriges Kapitel") { coordinator.previousChapter() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(!hasBook)
        Button("Nächstes Kapitel") { coordinator.nextChapter() }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(!hasBook)
    }
}

private struct AlwaysOnTopMenuCommand: View {
    @AppStorage("window.alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        Toggle("Immer im Vordergrund", isOn: Binding(
            get: { alwaysOnTop },
            set: { newValue in
                alwaysOnTop = newValue
                NSApp.setAlwaysOnTop(newValue)
            }
        ))
        .keyboardShortcut("f", modifiers: [.command, .control])
    }
}
