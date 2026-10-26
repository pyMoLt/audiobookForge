import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    @Binding var selection: SidebarSelection?
    var importingFiles: [String] = []
    var onImport: ([URL]) -> Void

    @State private var showFileImporter = false
    /// Einmaliges Angebot (Plan 5.2): Kapitel-Audio alter, fertiger Bücher
    /// löschen, sobald die M4B verifiziert ist. Nur nach Bestätigung.
    @State private var chapterAudioCandidates: [ChapterAudioMigrationOffer.Candidate] = []
    @State private var chapterAudioOfferMessage = ""
    @State private var showChapterAudioOffer = false
    @State private var chapterAudioResult: String?
    @Environment(SettingsStore.self) private var settingsStore
    @AppStorage("sidebar.showEmptyTopics") private var showEmptyTopics = false
    @State private var collapsedSections: Set<String> = []
    @State private var folders: [LibraryFolder] = []
    @State private var renamingFolder: LibraryFolder?
    @State private var renameFolderText = ""
    @State private var newFolderText = ""
    @State private var showNewFolder = false
    @Environment(\.appTextScale) private var appTextScale
    @Environment(PlaybackSession.self) private var playback

    @State private var settingsSearch = ""
    @State private var bookToDelete: BookProject?
    @State private var bookToRename: BookProject?
    @State private var renameBookTitle = ""
    @State private var showRenameBook = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if selection?.isSettings == true {
                    settingsSections
                } else {
                    librarySections
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .id(selection?.isSettings == true)
            .transition(.opacity)
            // Free space below the rows also answers a right-click.
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
            .contentShape(Rectangle())
            .contextMenu { if selection?.isSettings != true { globalActions } }
        }
        .scrollIndicators(.never)
        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 460)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(selection: $selection)
        }
        .animation(Theme.Motion.flow, value: selection?.isSettings == true)
        .onReceive(NotificationCenter.default.publisher(for: FolderStore.didChange)) { _ in
            folders = FolderStore.shared.folders()
        }
        .onAppear {
            presentChapterAudioOfferIfNeeded()
            folders = FolderStore.shared.folders()
            classifyUnclassifiedBooks()
            libraryStore.prefetchHydration()
        }
        .alert("Platz freigeben", isPresented: $showChapterAudioOffer) {
            Button("Jetzt freigeben") { confirmChapterAudioOffer() }
            Button("Später", role: .cancel) {}
        } message: {
            Text(chapterAudioOfferMessage)
        }
        .alert("Kapitel-Audio", isPresented: Binding(
            get: { chapterAudioResult != nil },
            set: { if !$0 { chapterAudioResult = nil } }
        )) {
            Button("OK", role: .cancel) { chapterAudioResult = nil }
        } message: {
            Text(chapterAudioResult ?? "")
        }
        .alert(
            "„\(bookToDelete?.title ?? "")“ löschen?",
            isPresented: Binding(
                get: { bookToDelete != nil },
                set: { if !$0 { bookToDelete = nil } }
            ),
            presenting: bookToDelete
        ) { book in
            Button("Löschen", role: .destructive) {
                deleteBook(book)
            }
            Button("Abbrechen", role: .cancel) {
                bookToDelete = nil
            }
        } message: { book in
            Text("Alle Projektdaten, Texte und Zwischen-Audiodateien werden unwiderruflich von der Festplatte gelöscht.")
        }
        .alert("Hörbuch umbenennen", isPresented: $showRenameBook) {
            TextField("Titel", text: $renameBookTitle)
            Button("Abbrechen", role: .cancel) {
                bookToRename = nil
                renameBookTitle = ""
            }
            Button("Speichern") {
                if let book = bookToRename {
                    let trimmed = renameBookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed != book.title {
                        var updated = book
                        updated.title = trimmed
                        libraryStore.upsert(updated)
                        libraryStore.flush()
                    }
                }
                bookToRename = nil
                renameBookTitle = ""
            }
        } message: {
            Text("Gib einen neuen Namen für das Hörbuch ein.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Buch importieren …", systemImage: "doc.badge.plus")
                    }
                    Button {
                        newFolderText = ""
                        showNewFolder = true
                    } label: {
                        Label("Neuer Ordner …", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Picker("Gruppierung", selection: Binding(
                        get: { settingsStore.settings.sidebarGrouping },
                        set: { settingsStore.settings.sidebarGrouping = $0 }
                    )) {
                        ForEach(SidebarGrouping.allCases) { grouping in
                            Text(grouping.displayName).tag(grouping)
                        }
                    }
                    if settingsStore.settings.sidebarGrouping == .topic {
                        Toggle("Leere Themen anzeigen", isOn: $showEmptyTopics)
                    }
                } label: {
                    Label("Aktionen", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .epub].compactMap { $0 }, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                onImport(urls)
            }
        }
        .alert("Neuer Ordner", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderText)
            Button("Anlegen") {
                _ = FolderStore.shared.add(name: newFolderText)
                folders = FolderStore.shared.folders()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Ordner umbenennen", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $renameFolderText)
            Button("Umbenennen") {
                if let folder = renamingFolder {
                    FolderStore.shared.rename(id: folder.id, to: renameFolderText)
                    folders = FolderStore.shared.folders()
                }
                renamingFolder = nil
            }
            Button("Abbrechen", role: .cancel) { renamingFolder = nil }
        } message: {
            Text("Bücher bleiben zugeordnet.")
        }
    }

    // MARK: - Library mode

    @ViewBuilder
    private var librarySections: some View {
        Section {
            Label {
                Text("Bibliothek")
                    .flowFont(.body, weight: .medium)
            } icon: {
                Image(systemName: "books.vertical")
                    .foregroundStyle(.tint)
            }
            .sidebarItem(SidebarSelection.home, selection: $selection)
            .padding(.vertical, 3)

            ForEach(importingFiles, id: \.self) { name in
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).lineLimit(1)
                        Text("Wird eingelesen …").flowFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        groupedLibrarySections
    }

    // MARK: - Settings mode (one navigation, template-style groups)

    @ViewBuilder
    private var settingsSections: some View {
        Section {
            Button {
                withAnimation(Theme.Motion.flow) { selection = .home }
            } label: {
                Label("Bibliothek", systemImage: "chevron.backward")
                    .flowFont(.body, weight: .medium)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Einstellungen durchsuchen", text: $settingsSearch)
                    .textFieldStyle(.plain)
                if !settingsSearch.isEmpty {
                    Button {
                        settingsSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .padding(.vertical, 4)
        }
        settingsGroup(.audiobook)
        settingsGroup(.text)
        settingsGroup(.app)
    }

    @ViewBuilder
    private func settingsGroup(_ group: SettingsPane.Group) -> some View {
        let panes = SettingsPane.allCases.filter { $0.group == group && $0.matches(settingsSearch) }
        VStack(alignment: .leading, spacing: 2) {
            if !panes.isEmpty { SidebarHeader(text: group.displayName) }
            ForEach(panes) { pane in
                Label {
                    Text(pane.title).flowFont(.body)
                } icon: {
                    Image(systemName: pane.systemImage)
                }
                .sidebarItem(SidebarSelection.settings(pane), selection: $selection)
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Gruppierung (Plan 9.5)

    /// Effektives Thema eines Buchs: manuelle Zuordnung vor Automatik.
    private func effectiveTopic(for book: BookProject) -> TopicClassifier.Topic {
        if let override = book.topicOverride, let topic = TopicClassifier.Topic.catalog.first(where: { $0.id == override }) {
            return topic
        }
        if let topicID = book.topic, let topic = TopicClassifier.Topic.catalog.first(where: { $0.id == topicID }) {
            return topic
        }
        return .other
    }

    /// Einmalige automatische Themen-Erkennung für neue Bücher (Plan 9.5).
    /// Läuft komplett abseits des Main-Threads: Texte werden per
    /// `LibraryLayout` direkt gelesen (Hydration ohne Store-Zugriff) und
    /// klassifiziert; nur die fertigen Upserts kommen zurück auf den
    /// Main-Actor. Ein großer Buchbestand blockiert so weder Start
    /// noch Bedienung.
    private func classifyUnclassifiedBooks() {
        let pending = libraryStore.books.filter { $0.topic == nil && $0.topicOverride == nil }
        guard !pending.isEmpty else { return }
        let root = libraryStore.rootURL
        Task { @MainActor in
            var classifications: [(UUID, TopicClassifier.Result)] = []
            await withTaskGroup(of: (UUID, TopicClassifier.Result).self) { group in
                for book in pending {
                    group.addTask {
                        let stored = LibraryLayout.readStoredBook(bookID: book.id, root: root)
                        var hydrated = stored?.book ?? book
                        LibraryLayout.hydrate(
                            &hydrated,
                            root: root,
                            sourceChaptersSameAsRaw: stored?.sourceChaptersSameAsRaw ?? false
                        )
                        let sample = Self.topicTextSample(for: hydrated)
                        let result = TopicClassifier.classify(
                            title: book.title,
                            author: book.author,
                            documentType: book.documentType,
                            textSample: sample,
                            languageCode: book.languageCode
                        )
                        return (book.id, result)
                    }
                }
                for await classification in group {
                    classifications.append(classification)
                }
            }
            for (bookID, result) in classifications {
                guard let index = libraryStore.books.firstIndex(where: { $0.id == bookID }),
                      libraryStore.books[index].topic == nil,
                      libraryStore.books[index].topicOverride == nil else { continue }
                var updated = libraryStore.books[index]
                updated.topic = result.topic.id
                updated.topicConfidence = result.confidence
                libraryStore.upsert(updated)
            }
        }
    }

    /// ~20 000 Zeichen aus den längsten Kapiteln, ohne Bildbeschreibungen.
    nonisolated private static func topicTextSample(for book: BookProject) -> String {
        let texts = book.chapters
            .map { ImageDescriptionMarker.unwrap($0.cleanedText) }
            .sorted { $0.count > $1.count }
        var sample = ""
        for text in texts {
            sample += text + "\n\n"
            if sample.count >= 20_000 { break }
        }
        return String(sample.prefix(20_000))
    }

    @ViewBuilder
    private var groupedLibrarySections: some View {
        let books = libraryStore.books.sorted { $0.createdAt > $1.createdAt }
        let grouping = settingsStore.settings.sidebarGrouping

        if grouping == .none {
            SidebarHeader(text: "Bücher")
            ForEach(books) { book in
                bookRow(book)
            }
        } else {
            // Eigene Ordner zuerst (manuell > Automatik, Plan 9.5).
            let folderBuckets = Dictionary(grouping: books.compactMap { b -> (UUID, BookProject)? in
                guard let f = b.folderID else { return nil }
                return (f, b)
            }, by: { $0.0 }).mapValues { $0.map(\.1) }

            ForEach(folders) { folder in
                let members = folderBuckets[folder.id] ?? []
                collapsibleSection(
                    title: folder.name,
                    systemImage: "folder",
                    storageKey: "sidebar.folder.\(folder.id.uuidString)",
                    count: members.count,
                    books: members,
                    dropHandler: { bookID in fileBook(bookID: bookID, into: folder) },
                    isFolder: true,
                    folder: folder
                )
            }

            let unfiled = books.filter { book in
                guard let folderID = book.folderID else { return true }
                return FolderStore.shared.folder(id: folderID) == nil
            }
            switch grouping {
            case .topic:
                let topicBuckets = Dictionary(grouping: unfiled, by: { effectiveTopic(for: $0) })
                let visibleTopics = TopicClassifier.Topic.catalog.filter { topic in
                    let count = topicBuckets[topic]?.count ?? 0
                    return count > 0 || showEmptyTopics
                }
                ForEach(visibleTopics) { topic in
                    let members = topicBuckets[topic] ?? []
                    collapsibleSection(
                        title: topic.displayName,
                        systemImage: topic.systemImage,
                        storageKey: "sidebar.topic.\(topic.id)",
                        count: members.count,
                        books: members,
                        dropHandler: { bookID in overrideTopic(bookID: bookID, to: topic) },
                        isFolder: false,
                        folder: nil
                    )
                }
            case .documentType:
                let groups = Dictionary(grouping: unfiled) { $0.documentType.displayName }
                ForEach(groups.keys.sorted(), id: \.self) { name in
                    collapsibleSection(title: name, systemImage: "doc", storageKey: "sidebar.doctype.\(name)", count: groups[name]?.count ?? 0, books: groups[name] ?? [], dropHandler: nil, isFolder: false, folder: nil)
                }
            case .author:
                let groups = Dictionary(grouping: unfiled) { $0.author.isEmpty ? "Unbekannt" : $0.author }
                ForEach(groups.keys.sorted(), id: \.self) { name in
                    collapsibleSection(title: name, systemImage: "person", storageKey: "sidebar.author.\(name)", count: groups[name]?.count ?? 0, books: groups[name] ?? [], dropHandler: nil, isFolder: false, folder: nil)
                }
            case .status:
                let groups = Dictionary(grouping: unfiled) { $0.status.displayName }
                ForEach(groups.keys.sorted(), id: \.self) { name in
                    collapsibleSection(title: name, systemImage: "info.circle", storageKey: "sidebar.status.\(name)", count: groups[name]?.count ?? 0, books: groups[name] ?? [], dropHandler: nil, isFolder: false, folder: nil)
                }
            case .none:
                EmptyView()
            }
        }
    }

    /// Gruppe mit Zähler, einklappbarer DisclosureGroup und Drop-Ziel.
    @ViewBuilder
    private func collapsibleSection(
        title: String,
        systemImage: String,
        storageKey: String,
        count: Int,
        books: [BookProject],
        dropHandler: ((UUID) -> Void)?,
        isFolder: Bool,
        folder: LibraryFolder? = nil
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { !collapsedSections.contains(storageKey) },
                set: { expanded in
                    if expanded {
                        collapsedSections.remove(storageKey)
                    } else {
                        collapsedSections.insert(storageKey)
                    }
                }
            )
        ) {
            ForEach(books) { book in
                bookRow(book)
            }
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text(title)
                        .flowFont(.callout, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(title)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("\(count)")
                    .flowFont(.caption, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.vertical, 4)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            .contextMenu {
                if let folder {
                    Button("Umbenennen …") {
                        renameFolderText = folder.name
                        renamingFolder = folder
                    }
                    Button("Löschen …", role: .destructive) {
                        deleteFolder(folder)
                    }
                }
                Divider()
                globalActions
            }
            .dropDestination(for: String.self) { dropped, _ in
                guard let idString = dropped.first,
                      let id = UUID(uuidString: idString),
                      let dropHandler else { return false }
                dropHandler(id)
                return true
            }
        }
    }

    private func bookRow(_ book: BookProject) -> some View {
        // Lauf-/Fortschritts-Lookups bewusst IN der Zeile (BookRow liest den
        // PipelineController selbst): sonst müsste dieser Body bei jedem
        // Progress-Tick (4/s) die komplette Gruppierung neu berechnen —
        // Hauptursache für den Beach Ball während laufender Generierung.
        BookRow(book: book)
        .sidebarItem(SidebarSelection.book(book.id), selection: $selection)
        .draggable(book.id.uuidString)
        .contextMenu {
            Button("Hörbuch umbenennen …", systemImage: "pencil") {
                bookToRename = book
                renameBookTitle = book.title
                showRenameBook = true
            }
            moveMenu(for: book)
            if book.status == .completed {
                Button("Neu vertonen …", systemImage: "waveform.badge.mic") {
                    NotificationCenter.default.post(name: .openRevoice, object: book.id)
                }
            }
            Divider()
            Button("Aus Bibliothek entfernen", role: .destructive) {
                bookToDelete = book
            }
            Divider()
            globalActions
        }
    }

    private func deleteBook(_ book: BookProject) {
        pipelineController.cancelProcessing(bookID: book.id)
        if playback.bookID == book.id { playback.close() }
        libraryStore.remove(book)
        ChapterAudioStore.removeChapterAudio(bookID: book.id)
        let logsDir = AppPaths.applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        if let logFiles = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
            for file in logFiles where file.lastPathComponent.contains(book.id.uuidString) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        libraryStore.flush()
        if selection == .book(book.id) { selection = nil }
        bookToDelete = nil
    }

    /// Right-click anywhere in the library sidebar: import or new folder.
    @ViewBuilder
    private var globalActions: some View {
        Button {
            showFileImporter = true
        } label: {
            Label("Buch importieren …", systemImage: "doc.badge.plus")
        }
        Button {
            newFolderText = ""
            showNewFolder = true
        } label: {
            Label("Neuer Ordner …", systemImage: "folder.badge.plus")
        }
    }

    /// Tastatur-Alternative zum Ziehen (Plan 9.5): Verschieben per Menü.
    @ViewBuilder
    private func moveMenu(for book: BookProject) -> some View {
        Menu("Verschieben nach …") {
            ForEach(TopicClassifier.Topic.catalog) { topic in
                Button {
                    overrideTopic(bookID: book.id, to: topic)
                } label: {
                    Label(topic.displayName, systemImage: topic.systemImage)
                }
            }
            if !folders.isEmpty {
                Divider()
                ForEach(folders) { folder in
                    Button(folder.name) {
                        fileBook(bookID: book.id, into: folder)
                    }
                }
            }
            Divider()
            Button("Zurück zur Automatik") {
                var updated = libraryStore.book(id: book.id) ?? book
                updated.topicOverride = nil
                updated.folderID = nil
                libraryStore.upsert(updated)
            }
        }
    }

    private func overrideTopic(bookID: UUID, to topic: TopicClassifier.Topic) {
        guard var updated = libraryStore.book(id: bookID) else { return }
        updated.topicOverride = topic.id
        updated.folderID = nil
        libraryStore.upsert(updated)
    }

    private func fileBook(bookID: UUID, into folder: LibraryFolder) {
        guard var updated = libraryStore.book(id: bookID) else { return }
        updated.folderID = folder.id
        libraryStore.upsert(updated)
    }

    /// Ordner löschen: Bücher wandern zurück in die automatische Gruppierung.
    private func deleteFolder(_ folder: LibraryFolder) {
        for book in libraryStore.books where book.folderID == folder.id {
            var updated = book
            updated.folderID = nil
            libraryStore.upsert(updated)
        }
        FolderStore.shared.delete(id: folder.id)
        folders = FolderStore.shared.folders()
    }

    /// One-time offer on first v3 start: completed books whose verified
    /// M4B/M4A exists can free their intermediate chapter audio. Shown
    /// once per library (never automatically deleted).
    private func presentChapterAudioOfferIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: ChapterAudioMigrationOffer.offerShownDefaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: ChapterAudioMigrationOffer.offerShownDefaultsKey)
        // Platz-Summe und Kandidaten erfordern Festplattenzugriff je Buch —
        // abseits des Main-Threads, der Dialog erscheint erst danach.
        let books = libraryStore.books
        let root = AppPaths.chapterAudioRoot
        Task { @MainActor in
            let candidates = await Task.detached(priority: .utility) {
                ChapterAudioMigrationOffer.candidates(from: books, chapterAudioRoot: root)
            }.value
            guard !candidates.isEmpty else { return }
            chapterAudioCandidates = candidates
            let total = candidates.reduce(0) { $0 + $1.savingsBytes }
            chapterAudioOfferMessage = """
                Die fertigen Hörbuch-Dateien folgender Bücher sind vorhanden und können direkt wiedergegeben werden:
                \(candidates.map(\.title).joined(separator: ", "))

                Kapitel-Audio zwischenspeicher löschen und \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) freigeben? Jedes Buch wird vorher geprüft; bei Zweifel bleibt alles erhalten.
                """
            showChapterAudioOffer = true
        }
    }

    private func confirmChapterAudioOffer() {
        let candidates = chapterAudioCandidates
        chapterAudioCandidates = []
        guard !candidates.isEmpty else { return }
        Task { @MainActor in
            guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: AppSettings()) else {
                chapterAudioResult = "ffmpeg/ffprobe wurde nicht gefunden — Kapitel-Audio bleibt erhalten."
                return
            }
            let lines = await ChapterAudioMigrationOffer.release(
                candidates,
                libraryStore: libraryStore,
                ffmpeg: ffmpeg,
                chapterAudioRoot: AppPaths.chapterAudioRoot
            )
            chapterAudioResult = lines.joined(separator: "\n")
        }
    }
}

private struct BookRow: View {
    @Environment(PipelineController.self) private var pipelineController
    @Environment(PlaybackSession.self) private var playback
    let book: BookProject

    private var isRunning: Bool { pipelineController.isRunning(book.id) }
    private var progress: RunProgress? { pipelineController.progress[book.id] }
    private var queuePosition: Int? {
        pipelineController.queuedBookIDs.firstIndex(of: book.id).map { $0 + 1 }
    }

    var body: some View {
        HStack(spacing: 10) {
            BookCoverView(book: book, width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .flowFont(.body)
                    .lineLimit(1)
                    .help(book.title)
                subtitle
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var subtitle: some View {
        if isRunning, let progress {
            Text("\(progress.stage.displayName) · \(Int((progress.overallFraction * 100).rounded())) %")
                .flowFont(.caption)
                .foregroundStyle(.tint)
                .monospacedDigit()
        } else if let queuePosition {
            Text("Warteschlange · Platz \(queuePosition)")
                .flowFont(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch book.status {
            case .needsReview:
                Text("Bereit zur Prüfung").flowFont(.caption).foregroundStyle(.tint)
            case .paused:
                Text("Pausiert").flowFont(.caption).foregroundStyle(.orange)
            case .failed:
                Text("Fehlgeschlagen").flowFont(.caption).foregroundStyle(.red)
            default:
                if !book.author.isEmpty {
                    Text(book.author)
                        .flowFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isRunning {
            ProgressRing(fraction: progress?.overallFraction ?? 0, lineWidth: 2.5)
                .frame(width: 16, height: 16)
        } else if playback.bookID == book.id, playback.coordinator.isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.tint)
                .flowFont(.caption)
        } else if book.status == .failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).flowFont(.caption)
        } else if book.status == .paused {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange).flowFont(.caption)
        }
    }
}

/// Sidebar bottom: mini player for the loaded book + settings entry.
private struct SidebarFooter: View {
    @Binding var selection: SidebarSelection?
    @Environment(PlaybackSession.self) private var playback
    @Environment(LibraryStore.self) private var libraryStore

    var body: some View {
        VStack(spacing: 8) {
            if let bookID = playback.bookID, let book = libraryStore.books.first(where: { $0.id == bookID }),
               selection != .book(bookID) {
                MiniPlayer(book: book, coordinator: playback.coordinator) {
                    selection = .book(bookID)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if selection?.isSettings != true {
                Button {
                    withAnimation(Theme.Motion.flow) { selection = .settings(.voices) }
                } label: {
                    Label("Einstellungen", systemImage: "gearshape")
                        .flowFont(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Einstellungen öffnen (⌘,)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(Theme.Motion.flow, value: playback.bookID)
    }
}

/// Compact now-playing card at the bottom of the sidebar.
private struct MiniPlayer: View {
    let book: BookProject
    let coordinator: AudioPlayerCoordinator
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        BookCoverView(book: book, width: 34)
                        MiniPlayerTitles(book: book, coordinator: coordinator)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Zum Player")

                MiniPlayerPlayButton(coordinator: coordinator)
            }
            MiniPlayerProgressBar(coordinator: coordinator)
        }
        .padding(10)
        .flowGlass(cornerRadius: 16)
    }
}

private struct MiniPlayerTitles: View {
    let book: BookProject
    @ObservedObject var coordinator: AudioPlayerCoordinator

    private var chapterTitle: String {
        let chapters = book.sortedChapters
        return chapters.indices.contains(coordinator.currentChapterIndex) ? chapters[coordinator.currentChapterIndex].displayTitle : book.author
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title)
                .flowFont(.callout, weight: .semibold)
                .lineLimit(1)
            Text(chapterTitle)
                .flowFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct MiniPlayerPlayButton: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator

    var body: some View {
        Button {
            coordinator.togglePlayPause()
        } label: {
            Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                .appFont(size: 13, weight: .bold)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(coordinator.isPlaying ? "Pause" : "Wiedergabe")
    }
}

private struct MiniPlayerProgressBar: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator

    var body: some View {
        FlowProgressBar(fraction: coordinator.chapterDuration > 0 ? coordinator.chapterElapsed / coordinator.chapterDuration : 0, height: 3)
    }
}


import UniformTypeIdentifiers
private extension UTType {
    static var epub: UTType { UTType(filenameExtension: "epub") ?? .data }
}


// MARK: - Custom sidebar rows (accent-colored selection, no system list)

private struct SidebarItemModifier: ViewModifier {
    let tag: SidebarSelection
    @Binding var selection: SidebarSelection?
    @State private var hovering = false
    @Environment(\.flowAccent) private var accent

    func body(content: Content) -> some View {
        let isSelected = selection == tag
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(accent.color.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0)))
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(accent.color).frame(width: 3, height: 18).offset(x: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Theme.Motion.flow) { selection = tag }
            }
            .onHover { hovering = $0 }
            .animation(Theme.Motion.quick, value: isSelected)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension View {
    func sidebarItem(_ tag: SidebarSelection, selection: Binding<SidebarSelection?>) -> some View {
        modifier(SidebarItemModifier(tag: tag, selection: selection))
    }
}

private struct SidebarHeader: View {
    let text: String
    var body: some View {
        Text(L(text))
            .flowFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
