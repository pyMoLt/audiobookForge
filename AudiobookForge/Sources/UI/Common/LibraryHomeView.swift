import SwiftUI
import UniformTypeIdentifiers

/// The home screen: a bookshelf. "Weiterhören" (resume with one click),
/// "In Arbeit" (books being prepared or generated) and the full shelf.
/// Import works by dropping files anywhere on the window or via the
/// "Hinzufügen" tile — the old centered drop box is gone.
struct LibraryHomeView: View {
    @Binding var selection: SidebarSelection?
    var importingFiles: [String]
    var onImport: ([URL]) -> Void

    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PipelineController.self) private var pipelineController
    @Environment(PlaybackSession.self) private var playback
    @State private var showFileImporter = false
    @AppStorage("library.sort") private var sort: ShelfSort = .recent
    @Namespace private var shelfNamespace
    @State private var opening: BookProject?
    /// Folder list, refreshed whenever a folder is added/renamed/deleted.
    @State private var folders = FolderStore.shared.folders()
    /// Where the opening book was picked up: "face" (Continue Listening) or
    /// "spine" (shelf). The same book appears in both places, so each has
    /// its own matched-geometry id — sharing one hid the shelf spine.
    @State private var openingFrom = "spine"
    @State private var bookToDelete: BookProject?

    enum ShelfSort: String, CaseIterable, Identifiable {
        case recent, title, author
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return L("Neueste")
            case .title: return L("Titel")
            case .author: return L("Autor")
            }
        }
    }

    @AppStorage("continueListening.hiddenMap") private var hiddenMapRaw: String = "{}"

    private func decodeHiddenMap() -> [String: Double] {
        guard let data = hiddenMapRaw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return dict
    }

    private func hideFromContinueListening(_ bookID: UUID) {
        var map = decodeHiddenMap()
        map[bookID.uuidString] = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(map), let str = String(data: data, encoding: .utf8) {
            hiddenMapRaw = str
        }
    }

    private var books: [BookProject] { libraryStore.books }

    private var continueListening: [(BookProject, PlaybackProgressStore.Summary)] {
        let hidden = decodeHiddenMap()
        return books.filter { $0.status == .completed }
            .compactMap { book in PlaybackProgressStore.summary(for: book).map { (book, $0) } }
            .filter { $0.1.fraction < 0.995 }
            .filter { book, summary in
                if let hiddenAt = hidden[book.id.uuidString] {
                    let lastPlayed = summary.lastPlayedAt?.timeIntervalSince1970 ?? 0
                    return lastPlayed > hiddenAt
                }
                return true
            }
            .sorted { ($0.1.lastPlayedAt ?? .distantPast) > ($1.1.lastPlayedAt ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    private var inProgress: [BookProject] {
        books.filter { book in
            pipelineController.isRunning(book.id) || [.processing, .queued, .paused, .needsReview, .failed].contains(book.status)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private var shelf: [BookProject] {
        switch sort {
        case .recent: return books.sorted { $0.createdAt > $1.createdAt }
        case .title: return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: return books.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                if books.isEmpty && importingFiles.isEmpty {
                    welcome
                } else {
                    if !continueListening.isEmpty { continueSection }
                    if !inProgress.isEmpty || !importingFiles.isEmpty { inProgressSection }
                    shelfSection
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: FolderStore.didChange)) { _ in
            folders = FolderStore.shared.folders()
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollIndicators(.never)
        .overlay {
            if let opening {
                OpeningBookOverlay(book: opening, namespace: shelfNamespace, geometryID: "\(openingFrom)-\(opening.id.uuidString)")
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .epubDocument], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { onImport(urls) }
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
    }

    private func deleteBook(_ book: BookProject) {
        pipelineController.cancelProcessing(bookID: book.id)
        if playback.bookID == book.id { playback.close() }
        libraryStore.remove(book)
        libraryStore.flush()
        bookToDelete = nil
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = settingsStore
        return PageHeader(systemImage: "books.vertical.fill", title: "Bibliothek", subtitle: headerSubtitle) {
            HStack(spacing: 10) {
                PillPicker(selection: $store.settings.defaultDocumentType,
                           options: DocumentType.allCases.map { PillOption(value: $0, label: $0.displayName, systemImage: $0.systemImage) })
                    .help("Dokumenttyp für neue Importe — „Paper“ nur für wissenschaftliche Artikel.")
                Button {
                    showFileImporter = true
                } label: {
                    Label("Importieren", systemImage: "plus")
                }
                .buttonStyle(FlowButtonStyle(variant: .prominent))
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private var headerSubtitle: String {
        let count = books.count
        let ready = books.filter { $0.status == .completed }.count
        let hours = books.filter { $0.status == .completed }
            .map { $0.chapters.compactMap(\.audioDurationSeconds).reduce(0, +) }
            .reduce(0, +)
        if count == 0 { return "Noch keine Bücher — PDF oder EPUB hineinziehen" }
        let countText = ListeningTimeFormatter.abbreviateCount(count)
        let readyText = ListeningTimeFormatter.abbreviateCount(ready)
        var parts = [count == 1 ? L("1 Buch") : String(localized: "\(countText) Bücher")]
        if ready > 0 { parts.append(String(localized: "\(readyText) hörbereit")) }
        // Listening habit (v3.2) instead of the library's total length.
        let today = ListeningStats.today()
        let thisMonth = ListeningStats.thisMonth()
        if hours > 0 || today > 0 || thisMonth > 0 {
            if today > 0 {
                parts.append(String(localized: "heute \(ListeningTimeFormatter.compact(today)) gehört"))
            }
            if thisMonth > 0 {
                parts.append(String(localized: "diesen Monat \(ListeningTimeFormatter.compact(thisMonth))"))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Sections

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Weiterhören", systemImage: "bookmark.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom, spacing: 26) {
                        ForEach(continueListening, id: \.0.id) { book, summary in
                            FaceOutBook(book: book, summary: summary, isCurrent: playback.bookID == book.id,
                                        namespace: shelfNamespace, isOpening: opening?.id == book.id && openingFrom == "face") {
                                openingFrom = "face"
                                open(book)
                            } onPlay: {
                                resume(book)
                            } onRemove: {
                                withAnimation(Theme.Motion.flow) {
                                    hideFromContinueListening(book.id)
                                }
                            } onDelete: {
                                bookToDelete = book
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    DisplayBoard()
                    HStack(alignment: .top, spacing: 26) {
                        ForEach(continueListening, id: \.0.id) { book, summary in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title).flowFont(.callout, weight: .semibold).lineLimit(2)
                                Text("noch \(ListeningTimeFormatter.long(summary.remainingSeconds))")
                                    .flowFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 122, alignment: .leading)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation(Theme.Motion.flow) {
                                        hideFromContinueListening(book.id)
                                    }
                                } label: {
                                    Label(L("Aus Weiterhören entfernen"), systemImage: "xmark.circle")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    bookToDelete = book
                                } label: {
                                    Label(L("Aus Bibliothek entfernen"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                }
                .padding(.top, 14)
            }
            .scrollClipDisabled()
        }
    }

    private var inProgressSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Auf dem Schreibtisch", systemImage: "pencil.and.outline")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(importingFiles, id: \.self) { name in
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).flowFont(.body, weight: .medium).lineLimit(1)
                            Text("Wird eingelesen …").flowFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .flowSurface(cornerRadius: Theme.Radius.card)
                }
                ForEach(inProgress) { book in
                    WorkCard(book: book) { open(book) }
                }
            }
        }
    }

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                sectionTitle("Bücherregal", systemImage: "books.vertical")
                Spacer()
                Menu {
                    ForEach(ShelfDecor.catalog, id: \.sprite) { entry in
                        Button(L(entry.name)) { withAnimation(Theme.Motion.flow) { ShelfDecor.shared.add(entry.sprite) } }
                    }
                } label: {
                    Label("Dekorieren", systemImage: "sparkles")
                }
                .menuStyle(.button)
                .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                .fixedSize()
                .help("Gegenstände ins Regal stellen — danach per Drag an jeden freien Platz")
                SegmentedPills(selection: $sort, options: ShelfSort.allCases.map { PillOption(value: $0, label: $0.label) }, size: .small)
            }
            BookshelfView(
                compartments: ShelfArrangement.compartments(for: shelf, grouping: settingsStore.settings.sidebarGrouping, folders: folders),
                openingBookID: openingFrom == "spine" ? opening?.id : nil,
                namespace: shelfNamespace,
                onOpen: { book in openingFrom = "spine"; open(book) },
                onAdd: { showFileImporter = true }
            )
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            EmptyStateCard(
                systemImage: "waveform.and.person.filled",
                title: "Willkommen bei AudiobookForge",
                message: "Zieh ein PDF oder EPUB irgendwo ins Fenster — oder wähle eine Datei. Danach prüfst du Text und Stimme, und das Hörbuch entsteht komplett lokal auf deinem Mac."
            ) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Buch auswählen …", systemImage: "plus")
                }
                .buttonStyle(FlowButtonStyle(variant: .prominent, size: .large))
            }
            HStack(spacing: 14) {
                StatTile(label: "1 · Importieren", value: "PDF / EPUB", detail: "Kapitel und Text werden erkannt und bereinigt.", systemImage: "doc.badge.plus")
                StatTile(label: "2 · Prüfen", value: "Stimme & Text", detail: "Stimme wählen, Kapitel anpassen, Probe hören.", systemImage: "checklist")
                StatTile(label: "3 · Hören", value: "Mit Ambiente", detail: "Mitlesen, Kaminfeuer, Regen — wie du magst.", systemImage: "headphones")
            }
            .frame(maxWidth: 820)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(L(text), systemImage: systemImage)
            .flowFont(.title3)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
    }

    /// Pull the book out of the shelf, turn it to its cover, then open it.
    private func open(_ book: BookProject) {
        guard opening == nil else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) { opening = book }
        Task {
            try? await Task.sleep(for: .milliseconds(560))
            selection = .book(book.id)
            try? await Task.sleep(for: .milliseconds(80))
            opening = nil
        }
    }

    private func resume(_ book: BookProject) {
        open(book)
        Task {
            await playback.open(book)
            playback.coordinator.play()
        }
    }
}

// MARK: - Cards

private struct WorkCard: View {
    let book: BookProject
    var onOpen: () -> Void
    @Environment(PipelineController.self) private var pipelineController
    @State private var hovering = false

    private var progress: RunProgress? { pipelineController.progress[book.id] }

    var body: some View {
        HStack(spacing: 14) {
            BookCoverView(book: book, width: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).flowFont(.body, weight: .semibold).lineLimit(1)
                HStack(spacing: 6) {
                    statusBadge
                    if let remaining = progress?.estimatedTotalRemainingSeconds, pipelineController.isRunning(book.id) {
                        Text("noch \(DurationFormatter.short(remaining))")
                            .flowFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if pipelineController.isRunning(book.id) {
                    FlowProgressBar(fraction: progress?.overallFraction ?? 0, height: 4)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0.5)
        }
        .padding(14)
        .flowSurface(cornerRadius: Theme.Radius.card)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if pipelineController.isRunning(book.id) {
            StatusBadge(text: progress?.stage.displayName ?? "Läuft", systemImage: "waveform")
        } else {
            switch book.status {
            case .needsReview: StatusBadge(text: "Bereit zur Prüfung", systemImage: "checklist")
            case .queued: StatusBadge(text: "In der Warteschlange", systemImage: "clock", tint: .secondary)
            case .paused: StatusBadge(text: "Pausiert", systemImage: "pause.fill", tint: .orange)
            case .failed: StatusBadge(text: "Fehlgeschlagen", systemImage: "exclamationmark.triangle.fill", tint: .red)
            default: StatusBadge(text: book.status.rawValue, tint: .secondary)
            }
        }
    }
}

extension DocumentType {
    var systemImage: String {
        switch self {
        case .general: return "doc.text"
        case .book: return "book.closed"
        case .paper: return "graduationcap"
        case .report: return "chart.bar.doc.horizontal"
        }
    }
}

// MARK: - Book metaphors

/// A book on display, cover facing out, with a ribbon showing progress.
private struct FaceOutBook: View {
    let book: BookProject
    let summary: PlaybackProgressStore.Summary
    var isCurrent: Bool
    var namespace: Namespace.ID
    var isOpening: Bool
    var onOpen: () -> Void
    var onPlay: () -> Void
    var onRemove: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        BookCoverView(book: book, width: 122)
            .overlay(alignment: .topTrailing) {
                RibbonShape()
                    .fill(.tint)
                    .frame(width: 11, height: 30 + 40 * summary.fraction)
                    .offset(x: -14, y: -4)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .overlay {
                if hovering {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .appFont(size: 18, weight: .bold)
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .transition(.scale.combined(with: .opacity))
                    .help("Weiterhören")
                }
            }
            .matchedGeometryEffect(id: "face-\(book.id.uuidString)", in: namespace, isSource: !isOpening)
            .opacity(isOpening ? 0 : 1)
            .rotation3DEffect(.degrees(hovering ? 6 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
            .offset(y: hovering ? -6 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture(perform: onOpen)
            .contextMenu {
                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label(L("Aus Weiterhören entfernen"), systemImage: "xmark.circle")
                    }
                }
                if let onDelete {
                    Divider()
                    Button(role: .destructive, action: onDelete) {
                        Label(L("Aus Bibliothek entfernen"), systemImage: "trash")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isCurrent {
                    Capsule().fill(.tint).frame(width: 26, height: 3).offset(y: 9)
                }
            }
            .help("\(book.title) — \(Int(summary.fraction * 100)) % gehört")
    }
}

/// The glass board the face-out books stand on.
private struct DisplayBoard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PixelWood(vertical: false, dark: colorScheme == .dark)
            .frame(height: PixelShelf.unit * 4)
            .background {
                Rectangle()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18))
                    .offset(x: PixelShelf.unit, y: PixelShelf.unit * 2)
            }
    }
}

/// Opening animation: the pulled book turns from spine to cover and grows
/// toward the reader before the player takes over.
private struct OpeningBookOverlay: View {
    let book: BookProject
    var namespace: Namespace.ID
    var geometryID: String
    @State private var turned = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(turned ? 0.85 : 0)
                .ignoresSafeArea()
            BookCoverView(book: book, width: 230)
                .matchedGeometryEffect(id: geometryID, in: namespace, isSource: true)
                .rotation3DEffect(.degrees(turned ? 0 : 75), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
                .scaleEffect(turned ? 1 : 0.7)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.8)) { turned = true }
        }
    }
}
