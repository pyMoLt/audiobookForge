import SwiftUI

@main
struct AudiobookForgeApp: App {
    @State private var libraryStore = LibraryStore()
    @State private var settingsStore = SettingsStore()
    @State private var pipelineController: PipelineController

    init() {
        let library = LibraryStore()
        let settings = SettingsStore()
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
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryStore)
                .environment(settingsStore)
                .environment(pipelineController)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
