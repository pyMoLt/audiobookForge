import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case book(UUID)
    case settings
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PipelineController.self) private var pipelineController

    @State private var selection: SidebarSelection?
    @State private var isImporting = false
    @State private var importError: String?
    /// Files currently being read in (shown in the sidebar right away, so
    /// a large textbook doesn't look like nothing happened).
    @State private var importingFiles: [String] = []

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, importingFiles: importingFiles, onImport: importDocuments)
        } detail: {
            detailView
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            selection = .home
                        } label: {
                            Label("Übersicht", systemImage: "house")
                        }
                        .help("Zurück zur Übersicht und zum Import neuer Bücher")
                        .disabled(selection == .home || selection == nil)
                    }
                }
        }
        .alert("Import fehlgeschlagen", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .none, .home:
            ImportDropZone(onImport: importDocuments)
        case .settings:
            SettingsView()
        case .book(let id):
            if let book = libraryStore.book(id: id) {
                BookDetailView(bookID: book.id)
            } else {
                ImportDropZone(onImport: importDocuments)
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
