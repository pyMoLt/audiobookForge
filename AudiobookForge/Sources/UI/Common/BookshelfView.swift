import SwiftUI
import AppKit
import CoreImage

// MARK: - Shelf model (pure)

/// One shelf compartment ("Fach"): a labeled group of books.
struct ShelfCompartment: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    var books: [BookProject]
}

enum ShelfArrangement {
    /// Groups books like the sidebar does: manual folders first, then the
    /// chosen grouping (topic by default). Empty groups are dropped.
    static func compartments(for books: [BookProject], grouping: SidebarGrouping, folders: [LibraryFolder]) -> [ShelfCompartment] {
        var result: [ShelfCompartment] = []
        let folderIDs = Set(folders.map(\.id))
        for folder in folders {
            let members = books.filter { $0.folderID == folder.id }
            if !members.isEmpty {
                result.append(ShelfCompartment(id: "folder.\(folder.id)", title: folder.name, systemImage: "folder", books: members))
            }
        }
        let rest = books.filter { $0.folderID == nil || !folderIDs.contains($0.folderID!) }
        switch grouping {
        case .topic:
            for topic in TopicClassifier.Topic.catalog {
                let members = rest.filter { topicID(of: $0) == topic.id }
                if !members.isEmpty {
                    result.append(ShelfCompartment(id: "topic.\(topic.id)", title: topic.displayName, systemImage: topic.systemImage, books: members))
                }
            }
        case .documentType:
            for type in DocumentType.allCases {
                let members = rest.filter { $0.documentType == type }
                if !members.isEmpty {
                    result.append(ShelfCompartment(id: "type.\(type.rawValue)", title: type.displayName, systemImage: type.systemImage, books: members))
                }
            }
        case .author:
            let groups = Dictionary(grouping: rest) { $0.author.isEmpty ? "Unbekannt" : $0.author }
            for name in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                result.append(ShelfCompartment(id: "author.\(name)", title: name, systemImage: "person", books: groups[name] ?? []))
            }
        case .status:
            for status in [BookProjectStatus.completed, .processing, .queued, .paused, .needsReview, .failed] {
                let members = rest.filter { $0.status == status }
                if !members.isEmpty {
                    result.append(ShelfCompartment(id: "status.\(status.rawValue)", title: status.displayName, systemImage: status.systemImage, books: members))
                }
            }
        case .none:
            if !rest.isEmpty {
                result.append(ShelfCompartment(id: "all", title: "Alle Bücher", systemImage: "books.vertical", books: rest))
            }
        }
        return result
    }

    static func topicID(of book: BookProject) -> String {
        let known = Set(TopicClassifier.Topic.catalog.map(\.id))
        if let override = book.topicOverride, known.contains(override) { return override }
        if let topic = book.topic, known.contains(topic) { return topic }
        return TopicClassifier.Topic.other.id
    }

    /// Spine thickness grows with the listening time (a thick book looks
    /// thick): 26…58 pt.
    static func spineWidth(for book: BookProject) -> CGFloat {
        let hours = book.chapters.compactMap(\.audioDurationSeconds).reduce(0, +) / 3600
        let byLength = hours > 0 ? hours * 3.2 : Double(book.chapters.count) * 0.9
        return CGFloat(26 + min(32, byLength))
    }

    /// Stable, slightly varied spine height (real shelves are uneven).
    static func spineHeight(for book: BookProject) -> CGFloat {
        let bytes = book.id.uuid
        let jitter = CGFloat((Int(bytes.3) ^ Int(bytes.11)) % 46)
        return 172 + jitter
    }
}

extension BookProjectStatus {
    var displayName: String {
        switch self {
        case .needsReview: return L("Zur Prüfung")
        case .queued: return L("Warteschlange")
        case .processing: return L("In Arbeit")
        case .paused: return L("Pausiert")
        case .completed: return L("Hörbereit")
        case .failed: return L("Fehlgeschlagen")
        }
    }

    var systemImage: String {
        switch self {
        case .needsReview: return "checklist"
        case .queued: return "clock"
        case .processing: return "waveform"
        case .paused: return "pause.circle"
        case .completed: return "headphones"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Bookcase view

/// The library as a real bookcase (cube shelving, like the reference
/// photo): one frame across the full width, equal glass compartments,
/// continuous shelf boards with a small label under every compartment.
/// Books stand spine-out; hover pulls a book out, clicking opens it.
struct BookshelfView: View {
    let compartments: [ShelfCompartment]
    var openingBookID: UUID?
    var namespace: Namespace.ID
    var onOpen: (BookProject) -> Void
    var onAdd: () -> Void

    @State private var width: CGFloat = 900
    @State private var bookToDelete: BookProject?
    @State private var bookToRename: BookProject?
    @State private var renameBookTitle = ""
    @State private var showRenameBookAlert = false
    @State private var bookToMoveToNewFolder: BookProject?
    @State private var showNewFolderAlert = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    @Environment(PlaybackSession.self) private var playback

    // Pixel grid (v3.2): everything is a multiple of one art pixel.
    static let upright: CGFloat = 3 * PixelShelf.unit
    static let board: CGFloat = 4 * PixelShelf.unit
    static let cubbyHeight: CGFloat = 59 * PixelShelf.unit

    enum Cubby: Identifiable {
        case books(id: String, title: String, systemImage: String, books: [BookProject], count: Int)
        case add
        case empty(Int)
        var id: String {
            switch self {
            case .books(let id, _, _, _, _): return id
            case .add: return "add"
            case .empty(let n): return "empty.\(n)"
            }
        }
    }

    private var columns: Int { max(1, Int((width + Self.upright) / (205 + Self.upright))) }
    /// Whole art pixels (v4): fractional widths made the pixel textures of
    /// boards, uprights and panels drift against each other while resizing.
    private var cubbyWidth: CGFloat {
        let c = CGFloat(columns)
        let raw = (width - Self.upright * (c + 1)) / c
        return max(PixelShelf.unit, (raw / PixelShelf.unit).rounded(.down) * PixelShelf.unit)
    }

    /// Splits overfull compartments across cubbies, adds the "new book"
    /// slot and pads the last row with empty compartments.
    private var cubbies: [Cubby] {
        var result: [Cubby] = []
        let inner = cubbyWidth - 36
        for compartment in compartments {
            var chunk: [BookProject] = []
            var used: CGFloat = 0
            var part = 0
            for book in compartment.books {
                let w = ShelfArrangement.spineWidth(for: book) + 3
                if used + w > inner, !chunk.isEmpty {
                    result.append(.books(id: "\(compartment.id).\(part)", title: compartment.title, systemImage: compartment.systemImage, books: chunk, count: compartment.books.count))
                    chunk = []; used = 0; part += 1
                }
                chunk.append(book); used += w
            }
            if !chunk.isEmpty {
                result.append(.books(id: "\(compartment.id).\(part)", title: compartment.title, systemImage: compartment.systemImage, books: chunk, count: compartment.books.count))
            }
        }
        result.append(.add)
        var n = 0
        // Enough empty compartments for every placed decoration (spawning
        // more objects can add a row).
        let neededSlots = (decor.items.filter { $0.cubby == nil }.map(\.slot).max() ?? -1) + 1
        while result.count % columns != 0 || result.count < columns * 2 || n < neededSlots {
            result.append(.empty(n)); n += 1
        }
        return result
    }

    var body: some View {
        let all = cubbies
        let rows = stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
        let cat = catPlan(rows: rows)
        let placement = decorPlacement(all)
        VStack(spacing: 0) {
            boardView(labels: nil)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    uprightView
                    ForEach(row) { cubby in
                        cubbyView(cubby, placement)
                            .frame(width: cubbyWidth, height: Self.cubbyHeight, alignment: .bottomLeading)
                            .background { cubbyBack }
                            .overlay(alignment: .top) { nameplate(for: cubby) }
                        uprightView
                    }
                }
                boardView(labels: nil)
            }
        }
        // The cat has the whole case: walks the boards, climbs the uprights.
        .overlay(alignment: .topLeading) {
            if let cat {
                ShelfCat(routine: cat, onDrop: { point in setCatHome(at: point, rows: rows) },
                         onCycleEnd: { catCycle += 1 })
            }
        }
        .alert("Ordner umbenennen", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $renameText)
            Button("Umbenennen") {
                if let folder = renamingFolder { FolderStore.shared.rename(id: folder, to: renameText) }
                renamingFolder = nil
            }
            Button("Abbrechen", role: .cancel) { renamingFolder = nil }
        }
        .alert("Neuer Ordner", isPresented: $creatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Anlegen") { FolderStore.shared.add(name: newFolderName) }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Neuen Bereich benennen", isPresented: $showNewFolderAlert) {
            TextField("Name des Bereichs", text: $newFolderName)
            Button("Erstellen") {
                guard let book = bookToMoveToNewFolder else { return }
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmed.isEmpty ? "Neuer Bereich" : trimmed
                let folder = FolderStore.shared.add(name: name)
                var updated = book
                updated.folderID = folder.id
                withAnimation(Theme.Motion.flow) {
                    libraryStore.upsert(updated)
                }
                bookToMoveToNewFolder = nil
                newFolderName = ""
            }
            Button("Abbrechen", role: .cancel) {
                bookToMoveToNewFolder = nil
                newFolderName = ""
            }
        } message: {
            Text("Gib einen Namen für diesen neuen Bibliotheksbereich ein.")
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
        .alert("Hörbuch umbenennen", isPresented: $showRenameBookAlert) {
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
        // Right-click on the shelf: put an object on it.
        .contextMenu {
            Menu {
                ForEach(ShelfDecor.catalog, id: \.sprite) { entry in
                    Button(L(entry.name)) { withAnimation(Theme.Motion.flow) { ShelfDecor.shared.add(entry.sprite) } }
                }
            } label: {
                Label("Ins Regal stellen", systemImage: "sparkles")
            }
            Button("Neuer Ordner …", systemImage: "folder.badge.plus") {
                newFolderName = ""
                creatingFolder = true
            }
            Button("Neues Buch importieren …", systemImage: "doc.badge.plus") { onAdd() }
        }
        // Hard pixel shadow under the case.
        .background {
            Rectangle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18))
                .offset(x: PixelShelf.unit * 2, y: PixelShelf.unit * 2)
        }
        // Measure the OFFERED width (min 0 / max ∞ takes exactly the
        // proposal). The case itself is as wide as its columns, so measuring
        // it would never let the column count drop in a narrower window.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func deleteBook(_ book: BookProject) {
        pipelineController.cancelProcessing(bookID: book.id)
        if playback.bookID == book.id { playback.close() }
        libraryStore.remove(book)
        libraryStore.flush()
        bookToDelete = nil
    }

    @ViewBuilder
    private func cubbyView(_ cubby: Cubby, _ placement: DecorPlacement) -> some View {
        switch cubby {
        case .books(let id, _, _, let books, _):
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(books) { book in
                    BookSpine(
                        book: book,
                        isOpening: openingBookID == book.id,
                        namespace: namespace,
                        onOpen: { onOpen(book) },
                        onRename: { book in
                            bookToRename = book
                            renameBookTitle = book.title
                            showRenameBookAlert = true
                        },
                        onDelete: { bookToDelete = $0 }
                    )
                }
                // A bookend keeps a short row upright.
                if books.count < 5 { PixelSprite(name: "shelf_bookend").padding(.leading, PixelShelf.unit) }
                // Objects placed beside the books (while there is room).
                ForEach(placement.inBooks[id] ?? []) { item in
                    decorItem(item, scale: placement.scale(of: item)).padding(.leading, PixelShelf.unit * 2)
                }
            }
            .padding(.horizontal, PixelShelf.unit * 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let item = items.first else { return false }
                if item.hasPrefix("abf-decor:") {
                    withAnimation(Theme.Motion.flow) { decor.move(String(item.dropFirst(10)), toBooks: id) }
                    return true
                }
                if item.hasPrefix("abf-book:") {
                    let bookIDString = String(item.dropFirst(9))
                    guard let bookUUID = UUID(uuidString: bookIDString),
                          let book = libraryStore.book(id: bookUUID) else { return false }
                    assignBook(book, toCubbyID: id)
                    return true
                }
                return false
            }
        case .add:
            AddSlot(action: onAdd)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case .empty(let n):
            // A lived-in shelf: objects in some compartments, air in others —
            // and the objects can be dragged to another compartment.
            ZStack(alignment: .bottom) {
                Color.clear.contentShape(Rectangle())
                HStack(alignment: .bottom, spacing: PixelShelf.unit * 3) {
                    ForEach(placement.inEmpty[n] ?? []) { item in decorItem(item, scale: placement.scale(of: item)) }
                }
            }
            // Safety net: nothing ever reaches over the uprights.
            .clipped()
            .dropDestination(for: String.self) { items, _ in
                guard let item = items.first else { return false }
                if item.hasPrefix("abf-decor:") {
                    withAnimation(Theme.Motion.flow) { decor.move(String(item.dropFirst(10)), to: n) }
                    return true
                }
                if item.hasPrefix("abf-book:") {
                    let bookIDString = String(item.dropFirst(9))
                    guard let bookUUID = UUID(uuidString: bookIDString),
                          let book = libraryStore.book(id: bookUUID) else { return false }
                    bookToMoveToNewFolder = book
                    newFolderName = ""
                    showNewFolderAlert = true
                    return true
                }
                return false
            }
        }
    }

    private var decor: ShelfDecor { ShelfDecor.shared }

    private func decorItem(_ item: ShelfDecor.Item, scale: CGFloat = 1) -> some View {
        PixelSprite(name: item.sprite, scale: scale)
            .modifier(CatNudgeWobble(id: item.id))
            .draggable("abf-decor:\(item.id)")
            .help("Verschieben: in ein anderes Fach ziehen")
            .contextMenu {
                Button("Duplizieren", systemImage: "plus.square.on.square") {
                    withAnimation(Theme.Motion.flow) { decor.duplicate(item.id) }
                }
                Menu {
                    ForEach(ShelfDecor.catalog, id: \.sprite) { entry in
                        Button(L(entry.name)) { withAnimation(Theme.Motion.flow) { decor.add(entry.sprite) } }
                    }
                } label: {
                    Label("Weitere Gegenstände", systemImage: "sparkles")
                }
                Divider()
                Button("Entfernen", systemImage: "trash", role: .destructive) {
                    withAnimation(Theme.Motion.flow) { decor.remove(item.id) }
                }
            }
    }

    struct DecorPlacement {
        var inBooks: [String: [ShelfDecor.Item]] = [:]
        var inEmpty: [Int: [ShelfDecor.Item]] = [:]
        /// Per item: 1, 0.75 or 0.5 — objects shrink in a narrow window
        /// instead of moving elsewhere or reaching over the uprights.
        var scales: [String: CGFloat] = [:]
        func scale(of item: ShelfDecor.Item) -> CGFloat { scales[item.id] ?? 1 }
    }

    static let decorScaleSteps: [CGFloat] = [1, 0.75, 0.5]

    private static func spriteWidth(_ item: ShelfDecor.Item) -> CGFloat {
        CGFloat(PixelSceneSupport.image(item.sprite)?.width ?? 20) * PixelShelf.unit
    }

    /// Where every object shows this time. Books win: an object placed beside
    /// books stays only while it fits; otherwise it shows in the nearest
    /// empty compartment with room — its saved place is kept, so it comes
    /// back once there is space again.
    private func decorPlacement(_ all: [Cubby]) -> DecorPlacement {
        let u = PixelShelf.unit
        var placement = DecorPlacement()
        var overflow: [ShelfDecor.Item] = []
        var freeWidth: [String: CGFloat] = [:]
        for cubby in all {
            guard case .books(let id, _, _, let books, _) = cubby else { continue }
            let spines = books.reduce(CGFloat(0)) { $0 + (ShelfArrangement.spineWidth(for: $1) / u).rounded() * u + 3 }
            let bookend: CGFloat = books.count < 5 ? 11 * u : 0
            freeWidth[id] = cubbyWidth - 6 * u - spines - bookend
        }
        for item in decor.items {
            if let target = item.cubby {
                // Stay beside the books, shrinking if needed; only when even
                // half size doesn't fit does the object show elsewhere.
                let full = Self.spriteWidth(item)
                if let free = freeWidth[target],
                   let step = Self.decorScaleSteps.first(where: { full * $0 + 2 * u <= free }) {
                    placement.inBooks[target, default: []].append(item)
                    placement.scales[item.id] = step
                    freeWidth[target] = free - full * step - 2 * u
                } else {
                    overflow.append(item)
                }
            } else {
                placement.inEmpty[item.slot, default: []].append(item)
            }
        }
        var slot = 0
        for item in overflow {
            while (placement.inEmpty[slot]?.count ?? 0) >= ShelfDecor.perSlot { slot += 1 }
            placement.inEmpty[slot, default: []].append(item)
        }
        // Empty compartments: the group shrinks together to fit the width.
        let available = cubbyWidth - 6 * u
        for (n, items) in placement.inEmpty {
            let total = items.map(Self.spriteWidth).reduce(0, +) + CGFloat(max(0, items.count - 1)) * 3 * u
            let step = Self.decorScaleSteps.first { total * $0 <= available } ?? Self.decorScaleSteps.last!
            for item in placement.inEmpty[n] ?? [] where step < 1 { placement.scales[item.id] = step }
        }
        return placement
    }

    /// The cat's day across the whole case: it rests in a free compartment,
    /// walks (and climbs) to the last book of the first book compartment and
    /// paws at it, then goes to a compartment on another level to sleep.
    @AppStorage("shelf.cat.row") private var catHomeRow = -1
    @AppStorage("shelf.cat.column") private var catHomeColumn = -1

    /// The cat was carried to `point` (case coordinates, bottom left):
    /// that compartment is its new home.
    private func setCatHome(at point: CGPoint, rows: [[Cubby]]) {
        let height = Self.board + CGFloat(rows.count) * (Self.cubbyHeight + Self.board)
        let fromTop = height - point.y
        let row = min(rows.count - 1, max(0, Int((fromTop - Self.board) / (Self.cubbyHeight + Self.board))))
        let column = min(columns - 1, max(0, Int((point.x - Self.upright) / (cubbyWidth + Self.upright))))
        catHomeRow = row
        catHomeColumn = column
    }

    /// Which round of the cat's day this is — every round picks new
    /// books and objects to play with.
    @State private var catCycle = 0

    /// The cat's next round across the whole case: from its home it visits
    /// two things (books or objects) and paws at them, sometimes naps in a
    /// random compartment, then comes home.
    private func catPlan(rows: [[Cubby]]) -> ShelfCatRoutine? {
        let u = PixelShelf.unit
        let height = Self.board + CGFloat(rows.count) * (Self.cubbyHeight + Self.board)
        func floorY(_ row: Int) -> CGFloat { height - (Self.board + CGFloat(row) * (Self.cubbyHeight + Self.board) + Self.cubbyHeight) }
        func left(_ column: Int) -> CGFloat { Self.upright + CGFloat(column) * (cubbyWidth + Self.upright) }
        let flat = rows.enumerated().flatMap { r, row in row.enumerated().map { (r, $0.offset, $0.element) } }
        guard !flat.isEmpty else { return nil }
        let placement = decorPlacement(rows.flatMap { $0 })

        // Things to play with, and where the cat stands (just right of them,
        // facing left).
        var targets: [ShelfCatRoutine.Target] = []
        for (r, c, cubby) in flat {
            var x = left(c) + u * 3
            switch cubby {
            case .books(let id, _, _, let books, _):
                for book in books {
                    x += (ShelfArrangement.spineWidth(for: book) / u).rounded() * u
                    targets.append(.init(id: "book-\(book.id.uuidString)", stand: CGPoint(x: x + 9 * u, y: floorY(r))))
                    x += 3
                }
                if books.count < 5 { x += 11 * u }
                for item in placement.inBooks[id] ?? [] {
                    x += 2 * u + Self.spriteWidth(item) * placement.scale(of: item)
                    targets.append(.init(id: item.id, stand: CGPoint(x: x + 9 * u, y: floorY(r))))
                }
            case .empty(let n):
                let items = placement.inEmpty[n] ?? []
                let widths = items.map { Self.spriteWidth($0) * placement.scale(of: $0) }
                var ix = left(c) + (cubbyWidth - widths.reduce(0, +) - CGFloat(max(0, items.count - 1)) * 3 * u) / 2
                for (item, w) in zip(items, widths) {
                    ix += w
                    targets.append(.init(id: item.id, stand: CGPoint(x: ix + 9 * u, y: floorY(r))))
                    ix += 3 * u
                }
            case .add: break
            }
        }
        let occupied = Set(decor.items.filter { $0.cubby == nil }.map(\.slot))
        // Where it was last set down, else the first free compartment.
        let home = flat.first { $0.0 == catHomeRow && $0.1 == catHomeColumn }
            ?? flat.first { if case .empty(let n) = $0.2 { return !occupied.contains(n) } else { return false } }
            ?? flat.last!
        var random = PixelSceneSupport.Random(catCycle &* 7919 &+ 17)
        let picked = targets.isEmpty ? [] : (0..<min(1, targets.count)).map { _ in targets[Int(random.next() * Double(targets.count)) % targets.count] }
        let napSpot: CGPoint? = random.next() < 0.85 ? {
            let spot = flat[Int(random.next() * Double(flat.count)) % flat.count]
            return CGPoint(x: left(spot.1) + cubbyWidth / 2, y: floorY(spot.0))
        }() : nil
        let uprights = (0...columns).map { Self.upright / 2 + CGFloat($0) * (cubbyWidth + Self.upright) }
        let maxX = left(columns - 1) + cubbyWidth - 10 * u
        return ShelfCatRoutine(
            home: CGPoint(x: left(home.1) + cubbyWidth / 2, y: floorY(home.0)),
            targets: picked.map { .init(id: $0.id, stand: CGPoint(x: min($0.stand.x, maxX), y: $0.stand.y)) },
            nap: napSpot, uprights: uprights, cycle: catCycle)
    }

    private var cubbyBack: some View {
        PixelPanel(dark: colorScheme == .dark)
    }

    private var uprightView: some View {
        PixelWood(vertical: true, dark: colorScheme == .dark)
            .frame(width: Self.upright, height: Self.cubbyHeight)
    }

    private func boardView(labels: [Cubby]?) -> some View {
        PixelWood(vertical: false, dark: colorScheme == .dark)
            .frame(height: Self.board)
            .zIndex(1)
    }

    /// Name plate on the compartment's upper edge — clearly belongs to
    /// THIS compartment. A category spanning several compartments shows
    /// it on the first one only.
    @State private var renamingFolder: UUID?
    @State private var renameText = ""
    @State private var creatingFolder = false
    @State private var newFolderName = ""

    /// Folder id of a compartment ("folder.<uuid>.<part>"), if it is one.
    private func folderID(of cubbyID: String) -> UUID? {
        guard cubbyID.hasPrefix("folder.") else { return nil }
        let parts = cubbyID.split(separator: ".")
        return parts.count >= 2 ? UUID(uuidString: String(parts[1])) : nil
    }

    /// Topic id of a compartment ("topic.<topicID>.<part>"), if it is one.
    private func topicID(of cubbyID: String) -> String? {
        guard cubbyID.hasPrefix("topic.") else { return nil }
        let parts = cubbyID.split(separator: ".")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    private func assignBook(_ book: BookProject, toCubbyID id: String) {
        var updated = book
        if let folder = folderID(of: id) {
            updated.folderID = folder
        } else if let topic = topicID(of: id) {
            updated.folderID = nil
            updated.topicOverride = topic
        } else {
            updated.folderID = nil
        }
        withAnimation(Theme.Motion.flow) {
            libraryStore.upsert(updated)
        }
    }

    @ViewBuilder
    private func nameplate(for cubby: Cubby) -> some View {
        if case .books(let id, let title, let image, _, let count) = cubby, id.hasSuffix(".0") {
            nameplateLabel(title: title, image: image, count: count)
                .contextMenu {
                    if let folder = folderID(of: id) {
                        Button("Umbenennen …", systemImage: "pencil") {
                            renameText = title
                            renamingFolder = folder
                        }
                    }
                    Button("Neuer Ordner …", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        creatingFolder = true
                    }
                    Button("Neues Buch importieren …", systemImage: "doc.badge.plus") { onAdd() }
                }
        }
    }

    @ViewBuilder
    private func nameplateLabel(title: String, image: String, count: Int) -> some View {
            HStack(spacing: 5) {
                Image(systemName: image).foregroundStyle(.tint)
                Text(title).lineLimit(1)
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .padding(.top, 10)
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func label(for cubby: Cubby) -> some View {
        switch cubby {
        case .books(_, let title, let image, _, let count):
            HStack(spacing: 4) {
                Image(systemName: image)
                Text(title).lineLimit(1)
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 11)
            .background(Capsule().fill(colorScheme == .dark ? Color(white: 0.14) : Color.white))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        default:
            EmptyView()
        }
    }
}

/// Decorations on the shelf (v3.2): any number of pixel objects, each in
/// an empty compartment (up to two per compartment), draggable, removable,
/// persisted across launches.
@MainActor @Observable
final class ShelfDecor {
    static let shared = ShelfDecor()

    struct Item: Codable, Identifiable, Equatable {
        var id: String
        var sprite: String
        var slot: Int
        /// Placed beside books in this compartment (books win when space
        /// runs out); nil = in empty compartment `slot`.
        var cubby: String? = nil
    }

    /// Sprites the "Decorate" menu offers, with their names.
    static let catalog: [(sprite: String, name: String)] = [
        ("shelf_plant", "Pflanze"), ("shelf_globe", "Globus"), ("shelf_books", "Bücherstapel"),
        ("shelf_hourglass", "Sanduhr"), ("shelf_candle", "Kerze"), ("shelf_mug", "Tasse"),
        ("shelf_frame", "Bild"), ("shelf_cactus", "Kaktus"),
    ]
    static let perSlot = 2
    private static let key = "shelf.decor.v2"

    private(set) var items: [Item]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let stored = try? JSONDecoder().decode([Item].self, from: data) {
            items = stored
        } else {
            // A lived-in default: objects in some compartments, air in others.
            items = [("shelf_plant", 0), ("shelf_globe", 2), ("shelf_books", 3), ("shelf_hourglass", 5), ("shelf_candle", 6)]
                .map { Item(id: UUID().uuidString, sprite: $0.0, slot: $0.1) }
        }
    }

    func items(in slot: Int) -> [Item] { items.filter { $0.slot == slot && $0.cubby == nil } }

    func move(_ id: String, toBooks cubby: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].cubby = cubby
        save()
    }

    func add(_ sprite: String) {
        // First compartment with room, counting up from the front.
        var slot = 0
        while items(in: slot).count >= Self.perSlot { slot += 1 }
        items.append(Item(id: UUID().uuidString, sprite: sprite, slot: slot))
        save()
    }

    func move(_ id: String, to slot: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].slot != slot || items[index].cubby != nil else { return }
        items[index].cubby = nil
        // A full compartment swaps its first object back.
        if items(in: slot).count >= Self.perSlot, let other = items.firstIndex(where: { $0.slot == slot }) {
            items[other].slot = items[index].slot
        }
        items[index].slot = slot
        save()
    }

    /// A copy next to the original (same compartment if there's room).
    func duplicate(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        var slot = item.slot
        while items(in: slot).count >= Self.perSlot { slot += 1 }
        items.append(Item(id: UUID().uuidString, sprite: item.sprite, slot: slot, cubby: item.cubby))
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - Pixel shelf parts

enum PixelShelf {
    /// Screen points per art pixel.
    static let unit: CGFloat = 4

    struct RGB { var r, g, b: Double; var color: Color { Color(red: r, green: g, blue: b) }
        func scaled(_ f: Double) -> RGB { RGB(r: min(1, r * f), g: min(1, g * f), b: min(1, b * f)) } }

    static let wood = RGB(r: 0.76, g: 0.50, b: 0.30)

    /// Stable pseudo-random value per art pixel (wood grain).
    static func grain(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ seed &* 83_492_791))
        h = (h ^ (h >> 13)) &* 0x5bd1e995
        return Double((h ^ (h >> 15)) & 0xFFFF) / 65535
    }
}

enum ShelfTextureCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 150
        return c
    }()

    static func wood(vertical: Bool, dark: Bool, cols: Int, rows: Int) -> CGImage? {
        guard cols > 0 && rows > 0 else { return nil }
        let key = "wood-\(vertical)-\(dark)-\(cols)-\(rows)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var pixels = [UInt32](repeating: 0, count: cols * rows)
        let base = PixelShelf.wood.scaled(dark ? 0.72 : 1)
        for y in 0..<rows {
            for x in 0..<cols {
                let along = vertical ? x : y, across = vertical ? cols : rows
                var c = base
                if along == 0 { c = base.scaled(1.16) }
                if along == across - 1 { c = base.scaled(0.62) }
                let g = PixelShelf.grain(vertical ? x : x / 5, vertical ? y / 5 : y, 3)
                if along > 0 && along < across - 1 && g > 0.86 { c = base.scaled(0.86) }
                let r = UInt32(max(0, min(255, c.r * 255)))
                let g8 = UInt32(max(0, min(255, c.g * 255)))
                let b = UInt32(max(0, min(255, c.b * 255)))
                pixels[y * cols + x] = 0xFF000000 | (b << 16) | (g8 << 8) | r
            }
        }
        guard let image = createCGImage(pixels: pixels, width: cols, height: rows) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func panel(dark: Bool, cols: Int, rows: Int) -> CGImage? {
        guard cols > 0 && rows > 0 else { return nil }
        let key = "panel-\(dark)-\(cols)-\(rows)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var pixels = [UInt32](repeating: 0, count: cols * rows)
        let base = dark ? PixelShelf.RGB(r: 0.21, g: 0.21, b: 0.25) : PixelShelf.RGB(r: 0.80, g: 0.81, b: 0.86)
        for y in 0..<rows {
            for x in 0..<cols {
                var c = base
                if x % 12 == 11 { c = base.scaled(dark ? 0.8 : 0.9) }
                if x % 12 == 0 { c = base.scaled(dark ? 1.12 : 1.03) }
                if y < 3 { c = c.scaled(dark ? 0.6 : 0.8 + Double(y) * 0.05) }
                if x == 0 || x == cols - 1 { c = c.scaled(0.85) }
                let r = UInt32(max(0, min(255, c.r * 255)))
                let g8 = UInt32(max(0, min(255, c.g * 255)))
                let b = UInt32(max(0, min(255, c.b * 255)))
                pixels[y * cols + x] = 0xFF000000 | (b << 16) | (g8 << 8) | r
            }
        }
        guard let image = createCGImage(pixels: pixels, width: cols, height: rows) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func spine(color: Color, gold: Color, cols: Int, rows: Int) -> CGImage? {
        guard cols > 0 && rows > 0 else { return nil }
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .brown
        let nsGold = NSColor(gold).usingColorSpace(.deviceRGB) ?? .yellow
        let key = "spine-\(nsColor.hashValue)-\(nsGold.hashValue)-\(cols)-\(rows)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var pixels = [UInt32](repeating: 0, count: cols * rows)
        let cr = nsColor.redComponent, cg = nsColor.greenComponent, cb = nsColor.blueComponent
        let gr = nsGold.redComponent, gg = nsGold.greenComponent, gb = nsGold.blueComponent

        func pack(r: CGFloat, g: CGFloat, b: CGFloat) -> UInt32 {
            let u8r = UInt32(max(0, min(255, r * 255)))
            let u8g = UInt32(max(0, min(255, g * 255)))
            let u8b = UInt32(max(0, min(255, b * 255)))
            return 0xFF000000 | (u8b << 16) | (u8g << 8) | u8r
        }

        let basePix = pack(r: cr, g: cg, b: cb)
        let darkPix = pack(r: cr * 0.58, g: cg * 0.58, b: cb * 0.58)
        let shadePix = pack(r: cr * 0.78, g: cg * 0.78, b: cb * 0.78)
        let lightPix = pack(r: min(1, cr + (1 - cr) * 0.22), g: min(1, cg + (1 - cg) * 0.22), b: min(1, cb + (1 - cb) * 0.22))
        let goldPix = pack(r: gr, g: gg, b: gb)

        for y in 0..<rows {
            for x in 0..<cols {
                var p = basePix
                if x == 0 || x == cols - 1 || y == 0 || y == rows - 1 { p = darkPix }
                else if x == 1 { p = lightPix }
                else if x == cols - 2 { p = shadePix }
                pixels[y * cols + x] = p
            }
        }
        if cols >= 5 {
            for row in [3, 5, rows - 6, rows - 4] where row > 0 && row < rows - 1 {
                for x in 2..<(cols - 2) {
                    pixels[row * cols + x] = goldPix
                }
            }
            let mid = cols / 2
            if rows > 10 {
                pixels[7 * cols + mid] = goldPix
                pixels[8 * cols + mid - 1] = goldPix
                pixels[8 * cols + mid + 1] = goldPix
                pixels[9 * cols + mid] = goldPix
            }
        }
        guard let image = createCGImage(pixels: pixels, width: cols, height: rows) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func createCGImage(pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        pixels.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return nil }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: baseAddr),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            return context.makeImage()
        }
    }
}

/// Wood for uprights and boards: lit edge, darker far edge, outline and a
/// little grain — all on the art-pixel grid.
struct PixelWood: View {
    var vertical: Bool
    var dark: Bool

    var body: some View {
        GeometryReader { proxy in
            let u = PixelShelf.unit
            let cols = max(1, Int((proxy.size.width / u).rounded(.up)))
            let rows = max(1, Int((proxy.size.height / u).rounded(.up)))
            if let img = ShelfTextureCache.wood(vertical: vertical, dark: dark, cols: cols, rows: rows) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// The compartment's back wall: grey vertical panels, shadow under the
/// board above (as in the design reference).
struct PixelPanel: View {
    var dark: Bool

    var body: some View {
        GeometryReader { proxy in
            let u = PixelShelf.unit
            let cols = max(1, Int((proxy.size.width / u).rounded(.up)))
            let rows = max(1, Int((proxy.size.height / u).rounded(.up)))
            if let img = ShelfTextureCache.panel(dark: dark, cols: cols, rows: rows) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// A generated pixel sprite (Resources/Scenes/shelf_*.png) at art scale.
struct PixelSprite: View {
    let name: String
    /// Shrinks the object to fit a narrow compartment (v4: 1, ¾ or ½ so
    /// the pixels stay even).
    var scale: CGFloat = 1

    var body: some View {
        if let image = PixelSceneSupport.image(name) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: CGFloat(image.width) * PixelShelf.unit * scale, height: CGFloat(image.height) * PixelShelf.unit * scale)
        }
    }
}

/// "Add a book" — an empty, dashed spine-shaped slot.
private struct AddSlot: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Rectangle()
                    .strokeBorder(Color.primary.opacity(hovering ? 0.45 : 0.25), style: StrokeStyle(lineWidth: PixelShelf.unit / 2, dash: [PixelShelf.unit * 2, PixelShelf.unit]))
                    .frame(width: PixelShelf.unit * 11, height: PixelShelf.unit * 46)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    .offset(y: hovering ? -10 : 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .help("Buch importieren (⌘O) — oder Dateien einfach ins Fenster ziehen")
    }
}

/// A book standing spine-out.
struct BookSpine: View {
    let book: BookProject
    var isOpening: Bool
    var namespace: Namespace.ID
    var onOpen: () -> Void
    var onRename: ((BookProject) -> Void)? = nil
    var onDelete: ((BookProject) -> Void)? = nil

    @State private var hovering = false
    @Environment(PipelineController.self) private var pipelineController
    @Environment(PlaybackSession.self) private var playback

    /// Snapped to whole art pixels.
    private var width: CGFloat { (ShelfArrangement.spineWidth(for: book) / PixelShelf.unit).rounded() * PixelShelf.unit }
    private var height: CGFloat { (ShelfArrangement.spineHeight(for: book) / PixelShelf.unit).rounded() * PixelShelf.unit }
    private var color: Color { CoverColorCache.color(for: book) }
    private var isRunning: Bool { pipelineController.isRunning(book.id) }
    private var listening: PlaybackProgressStore.Summary? { PlaybackProgressStore.summary(for: book) }

    var body: some View {
        Button(action: onOpen) {
            spine
        }
        .buttonStyle(.plain)
        .matchedGeometryEffect(id: "spine-\(book.id.uuidString)", in: namespace, isSource: !isOpening)
        .opacity(isOpening ? 0 : 1)
        .offset(y: hovering ? -PixelShelf.unit * 3 : 0)
        .modifier(CatNudgeWobble(id: "book-\(book.id.uuidString)"))
        .draggable("abf-book:\(book.id.uuidString)") {
            spine.frame(width: width, height: height)
        }
        .zIndex(hovering ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(book.title)
        .accessibilityHint("Buch öffnen")
        .contextMenu {
            Button("Öffnen", systemImage: "book") {
                onOpen()
            }
            if let onRename {
                Button("Hörbuch umbenennen …", systemImage: "pencil") {
                    onRename(book)
                }
            }
            if book.status == .completed {
                Button("Neu vertonen …", systemImage: "waveform.badge.mic") {
                    NotificationCenter.default.post(name: .openRevoice, object: book.id)
                }
            }
            if let onDelete {
                Divider()
                Button("Aus Bibliothek entfernen", systemImage: "trash", role: .destructive) {
                    onDelete(book)
                }
            }
        }
    }

    /// Spine design varies per book (stable by id): gold-stamped cloth or
    /// a paper title label — like a real mixed shelf.
    private var usesLabel: Bool { (Int(book.id.uuid.5) % 3) == 0 }

    private var spine: some View {
        ZStack(alignment: .bottom) {
            PixelSpineBody(color: color, gold: gold)
            if isRunning {
                // Being written: the spine fills up like ink rising.
                GeometryReader { proxy in
                    let fraction = pipelineController.progress[book.id]?.overallFraction ?? 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Color.white.opacity(0.28))
                            .frame(height: proxy.size.height * fraction)
                            .animation(.easeInOut(duration: 0.6), value: fraction)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                titleBlock
                Spacer(minLength: 0)
                Text(initials)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(gold)
                    .padding(.bottom, PixelShelf.unit * 3)
            }
            .padding(.top, PixelShelf.unit * 8)
        }
        .frame(width: width, height: height)
        .opacity(book.status == .completed || isRunning ? 1 : 0.86)
        .overlay(alignment: .top) {
            if let listening, listening.fraction > 0.005, listening.fraction < 0.995 {
                // Bookmark ribbon: you're in the middle of this one.
                VStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: PixelShelf.unit * 2, height: PixelShelf.unit * 6)
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.accentColor.mix(with: .black, by: 0.25)).frame(width: PixelShelf.unit, height: PixelShelf.unit)
                        Color.clear.frame(width: PixelShelf.unit, height: PixelShelf.unit)
                    }
                }
                .offset(x: width * 0.18, y: -PixelShelf.unit * 3)
            } else if book.status == .needsReview {
                // Unfinished manuscript: a pencil tucked into the book.
                PixelSprite(name: "shelf_pencil")
                    .offset(x: width * 0.2, y: -PixelShelf.unit * 5)
            }
        }
        .overlay(alignment: .top) {
            if playback.bookID == book.id, playback.coordinator.isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(gold)
                    .padding(.top, 40)
            }
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        let title = Text(book.title)
            .font(.system(size: min(12, width * 0.34), weight: .semibold, design: .serif))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .truncationMode(.tail)
        if usesLabel {
            // Paper label glued on the spine.
            title
                .foregroundStyle(Color(red: 0.2, green: 0.17, blue: 0.14))
                .padding(.horizontal, 6)
                .frame(width: height - PixelShelf.unit * 22, height: max(14, width - PixelShelf.unit * 3))
                .background(Rectangle().fill(Color(red: 0.96, green: 0.93, blue: 0.84)))
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: PixelShelf.unit / 4))
                .rotationEffect(.degrees(-90))
                .frame(width: width, height: height - PixelShelf.unit * 22)
        } else {
            title
                .foregroundStyle(gold)
                .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
                .frame(width: height - PixelShelf.unit * 22)
                .rotationEffect(.degrees(-90))
                .frame(width: width, height: height - PixelShelf.unit * 22)
        }
    }

    /// Gold foil on dark cloth, dark ink on light cloth.
    private var gold: Color {
        CoverColorCache.isLight(for: book) ? Color(red: 0.25, green: 0.2, blue: 0.14) : Color(red: 0.95, green: 0.83, blue: 0.55)
    }

    private var textColor: Color {
        CoverColorCache.isLight(for: book) ? Color.black.opacity(0.78) : Color.white.opacity(0.95)
    }

    private var initials: String {
        let parts = book.author.split(whereSeparator: { $0 == " " || $0 == "," }).prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "·" : letters.uppercased()
    }

    private var helpText: String {
        var parts = [book.title]
        if !book.author.isEmpty { parts.append(book.author) }
        if let listening, listening.fraction > 0.005 { parts.append(String(localized: "\(Int(listening.fraction * 100)) % gehört")) }
        else if book.status != .completed { parts.append(book.status.displayName) }
        return parts.joined(separator: " — ")
    }
}

/// Something the cat paws at wobbles — triggered by the cat itself at
/// the moment of the swipe (not by a separate clock).
struct CatNudgeWobble: ViewModifier {
    let id: String
    @State private var nudges = ShelfNudges.shared

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: nudges.count(id)) { view, angle in
            view.rotationEffect(.degrees(angle), anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                CubicKeyframe(-4.0, duration: 0.18)
                CubicKeyframe(1.5, duration: 0.22)
                CubicKeyframe(-3.0, duration: 0.18)
                CubicKeyframe(1.0, duration: 0.22)
                CubicKeyframe(-1.5, duration: 0.18)
                CubicKeyframe(0.0, duration: 0.25)
            }
        }
    }
}

/// Paw swipes, counted per target id (books "book-<uuid>", objects by id).
@MainActor @Observable
final class ShelfNudges {
    static let shared = ShelfNudges()
    private var counts: [String: Int] = [:]
    func count(_ id: String) -> Int { counts[id] ?? 0 }
    func nudge(_ id: String) { counts[id, default: 0] += 1 }
}

/// The spine as pixel art: cover-coloured cloth, dark/light edge columns,
/// gold bands near top and bottom and a small gold diamond emblem.
struct PixelSpineBody: View {
    let color: Color
    let gold: Color

    var body: some View {
        GeometryReader { proxy in
            let u = PixelShelf.unit
            let cols = max(1, Int((proxy.size.width / u).rounded()))
            let rows = max(1, Int((proxy.size.height / u).rounded()))
            if let img = ShelfTextureCache.spine(color: color, gold: gold, cols: cols, rows: rows) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// Bookmark ribbon with a notched end.
struct RibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.width * 0.55))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Cover colors

/// Average cover color (CIAreaAverage), cached per book — the spine takes
/// the book's own color like a real book does.
enum CoverColorCache {
    nonisolated(unsafe) private static var cache: [UUID: (Color, Bool)] = [:]
    private static let lock = NSLock()
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func color(for book: BookProject) -> Color { entry(for: book).0 }
    static func isLight(for book: BookProject) -> Bool { entry(for: book).1 }

    private static func entry(for book: BookProject) -> (Color, Bool) {
        lock.lock()
        if let cached = cache[book.id] { lock.unlock(); return cached }
        lock.unlock()
        let value = compute(book)
        lock.lock()
        cache[book.id] = value
        lock.unlock()
        return value
    }

    /// Root of the library, set once by the shelf (cover files on disk).
    nonisolated(unsafe) static var libraryRoot: URL?

    private static func coverFileData(for book: BookProject) -> Data? {
        guard let root = libraryRoot else { return nil }
        return (try? Data(contentsOf: LibraryLayout.coverThumbURL(root, bookID: book.id)))
            ?? (try? Data(contentsOf: LibraryLayout.coverURL(root, bookID: book.id)))
    }

    private static func compute(_ book: BookProject) -> (Color, Bool) {
        let fileData = book.coverImageData ?? coverFileData(for: book)
        if let data = fileData, let image = CIImage(data: data) {
            let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])
            if let output = filter?.outputImage {
                var pixel = [UInt8](repeating: 0, count: 4)
                context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
                // Deepen a bit: averages of covers tend to be muddy/pale.
                var r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
                let maxC = max(r, g, b), minC = min(r, g, b)
                if maxC - minC < 0.12 {
                    // Grey cover → keep it but slightly darker.
                    r *= 0.85; g *= 0.85; b *= 0.88
                } else {
                    let boost = 1.25
                    let mean = (r + g + b) / 3
                    r = min(1, mean + (r - mean) * boost)
                    g = min(1, mean + (g - mean) * boost)
                    b = min(1, mean + (b - mean) * boost)
                }
                let luminance = ContrastMath.luminance(red: r, green: g, blue: b)
                return (Color(red: r, green: g, blue: b), luminance > 0.45)
            }
        }
        // No cover: the generated cover's deep palette color.
        let palette: [(Double, Double, Double)] = [
            (0.35, 0.30, 0.75), (0.08, 0.40, 0.55), (0.70, 0.25, 0.25), (0.15, 0.42, 0.30),
            (0.55, 0.30, 0.10), (0.20, 0.24, 0.40), (0.62, 0.20, 0.45),
        ]
        let index = Int(book.id.uuid.0 ^ book.id.uuid.7 ^ book.id.uuid.15) % palette.count
        let (r, g, b) = palette[index]
        return (Color(red: r, green: g, blue: b), false)
    }
}

// MARK: - The shelf cat

/// One round of the cat's day (seconds), in the case's coordinates
/// (origin bottom left, y = the board it stands on). Each round has its own
/// targets; the cat swipes at them at `interactions` times.
struct ShelfCatRoutine: Equatable {
    struct Target: Equatable { var id: String; var stand: CGPoint }
    enum Act: Equatable { case sit, walk, climb, paw, sleep }
    struct Step: Equatable { var start: Double; var end: Double; var act: Act; var from: CGPoint; var to: CGPoint }

    private(set) var steps: [Step] = []
    private(set) var total = 0.0
    /// (time of the swipe, target id)
    private(set) var interactions: [(Double, String)] = []
    let cycle: Int

    static func == (a: Self, b: Self) -> Bool {
        a.steps == b.steps && a.cycle == b.cycle && a.interactions.map(\.1) == b.interactions.map(\.1)
    }

    init(home: CGPoint, targets: [Target], nap: CGPoint?, uprights: [CGFloat], cycle: Int) {
        self.cycle = cycle
        let walkSpeed: CGFloat = 70, climbSpeed: CGFloat = 55
        var here = home
        func add(_ act: Act, _ duration: Double, to target: CGPoint? = nil) {
            let destination = target ?? here
            steps.append(Step(start: total, end: total + duration, act: act, from: here, to: destination))
            total += duration
            here = destination
        }
        /// Along the board, to the nearest upright, up/down it, then along.
        func go(to target: CGPoint) {
            if abs(target.y - here.y) > 1 {
                let pole = uprights.min { abs($0 - here.x) + abs($0 - target.x) < abs($1 - here.x) + abs($1 - target.x) } ?? here.x
                if abs(pole - here.x) > 1 { add(.walk, max(0.6, Double(abs(pole - here.x) / walkSpeed)), to: CGPoint(x: pole, y: here.y)) }
                add(.climb, max(0.8, Double(abs(target.y - here.y) / climbSpeed)), to: CGPoint(x: pole, y: target.y))
            }
            if abs(target.x - here.x) > 1 { add(.walk, max(0.6, Double(abs(target.x - here.x) / walkSpeed)), to: target) }
        }
        add(.sit, 10)
        for target in targets {
            go(to: target.stand)
            add(.sit, 1.2)
            // The wobble starts immediately when the paw touches the item
            interactions.append((total + 0.15, target.id))
            add(.paw, 0.9)
            add(.sit, 3)
        }
        if let nap {
            go(to: nap)
            add(.sleep, 25)
            add(.sit, 4)
        }
        go(to: home)
        add(.sit, 6)
    }
}


/// A small pixel cat roaming its shelf row: sits and swishes its tail,
/// strolls to a book and paws at it, strolls on, curls up to sleep. One
/// long Core Animation loop — no per-frame work in the app.
struct ShelfCat: NSViewRepresentable {
    let routine: ShelfCatRoutine
    @Environment(\.energyAnimates) private var energyAnimates
    /// The cat was carried and set down here (case coordinates).
    var onDrop: (CGPoint) -> Void = { _ in }
    /// The round is over: plan the next one (new targets).
    var onCycleEnd: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ShelfCatView { ShelfCatView() }

    func updateNSView(_ view: ShelfCatView, context: Context) {
        view.onDrop = onDrop
        view.onCycleEnd = onCycleEnd
        view.configure(routine: routine, animated: !reduceMotion && energyAnimates)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShelfCatView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }
}

final class ShelfCatView: NSView {
    private let cat = CALayer()
    private var configured: (ShelfCatRoutine, Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cat.contents = PixelSceneSupport.image("shelf_cat")
        cat.magnificationFilter = .nearest
        cat.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(cat)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var onDrop: (CGPoint) -> Void = { _ in }
    var onCycleEnd: () -> Void = {}
    private var carrying = false
    /// Swipes and the end of the round, timed against the animation start.
    private var schedule: Task<Void, Never>?

    /// Only the cat itself catches the mouse — clicks beside it reach the
    /// books and objects underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let frame = (cat.presentation() ?? cat).frame.insetBy(dx: PixelShelf.unit * 3, dy: PixelShelf.unit * 2)
        return frame.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // Pick up: the cat dangles at the cursor while carried.
    override func mouseDown(with event: NSEvent) {
        carrying = true
        schedule?.cancel()
        NSCursor.closedHand.push()
        let point = convert(event.locationInWindow, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.removeAllAnimations()
        cat.transform = CATransform3DIdentity
        cat.contentsRect = CGRect(x: 10 / 11.0, y: 0, width: 1 / 11.0, height: 1)
        cat.position = CGPoint(x: point.x, y: point.y - cat.bounds.height * 0.85)
        CATransaction.commit()
        // A little wriggle while it hangs there.
        let wriggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wriggle.values = [0, 0.12, -0.12, 0.08, 0]
        wriggle.duration = 0.9
        wriggle.repeatCount = .infinity
        cat.add(wriggle, forKey: "wriggle")
    }

    override func mouseDragged(with event: NSEvent) {
        guard carrying else { return }
        let point = convert(event.locationInWindow, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.position = CGPoint(x: point.x, y: point.y - cat.bounds.height * 0.85)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard carrying else { return }
        carrying = false
        NSCursor.pop()
        cat.removeAnimation(forKey: "wriggle")
        let point = convert(event.locationInWindow, from: nil)
        let previous = configured
        configured = nil // the routine restarts from the new home
        onDrop(point)
        // Same compartment → SwiftUI sends no update; restart it ourselves.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.configured == nil, let previous else { return }
            self.configure(routine: previous.0, animated: previous.1)
        }
    }

    func configure(routine: ShelfCatRoutine, animated: Bool) {
        guard !carrying else { return }
        if let configured, configured.0 == routine, configured.1 == animated { return }
        let landing = configured == nil && cat.animation(forKey: "life") == nil && cat.contentsRect.minX > 0.9
        configured = (routine, animated)
        let u = PixelShelf.unit, frameCount = 11.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.bounds = CGRect(x: 0, y: 0, width: 20 * u, height: 16 * u)
        cat.position = routine.steps.first?.from ?? .zero
        cat.contentsRect = CGRect(x: 0, y: 0, width: 1 / frameCount, height: 1)
        cat.removeAllAnimations()
        CATransaction.commit()
        guard animated, !routine.steps.isEmpty else { return }

        let tick = 0.125
        var rects: [NSValue] = [], points: [NSValue] = [], poses: [NSValue] = []
        var facingRight = true
        var t = 0.0
        while t < routine.total {
            let step = routine.steps.first { t >= $0.start && t < $0.end } ?? routine.steps.last!
            let progress = CGFloat((t - step.start) / max(0.001, step.end - step.start))
            let local = t - step.start
            var point = step.from
            var pose = CATransform3DIdentity
            let frame: Int
            switch step.act {
            case .sit: frame = Int(local / 0.75) % 2
            case .sleep: frame = 6 + Int(local / 1.5) % 2
            case .paw: frame = 8 + Int(local / 0.375) % 2; facingRight = false // the book is to its left
            case .walk:
                frame = 2 + Int(local / 0.125) % 4
                point = CGPoint(x: step.from.x + (step.to.x - step.from.x) * progress, y: step.from.y)
                facingRight = step.to.x >= step.from.x
            case .climb:
                frame = 2 + Int(local / 0.125) % 4
                point = CGPoint(x: step.from.x, y: step.from.y + (step.to.y - step.from.y) * progress)
                // Head first along the upright: up or down.
                pose = CATransform3DMakeRotation(step.to.y > step.from.y ? .pi / 2 : -.pi / 2, 0, 0, 1)
            }
            if step.act != .climb { pose = CATransform3DMakeScale(facingRight ? 1 : -1, 1, 1) }
            rects.append(NSValue(rect: NSRect(x: Double(frame) / frameCount, y: 0, width: 1 / frameCount, height: 1)))
            points.append(NSValue(point: NSPoint(x: (point.x / u).rounded() * u, y: (point.y / u).rounded() * u)))
            poses.append(NSValue(caTransform3D: pose))
            t += tick
        }
        func track(_ keyPath: String, _ values: [NSValue]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.calculationMode = .discrete
            animation.duration = routine.total
            return animation
        }
        let now = CACurrentMediaTime()
        let group = CAAnimationGroup()
        group.animations = [track("contentsRect", rects), track("position", points), track("transform", poses)]
        group.duration = routine.total
        group.beginTime = now
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        cat.add(group, forKey: "life")
        // Swipes nudge their target exactly when the paw moves; at the end
        // of the round the next one (with new targets) is planned.
        schedule?.cancel()
        let interactions = routine.interactions, total = routine.total
        schedule = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            for (time, id) in interactions {
                let delay = max(0, time)
                try? await Task.sleep(until: start + .milliseconds(Int(delay * 1000)))
                guard !Task.isCancelled else { return }
                ShelfNudges.shared.nudge(id)
            }
            try? await Task.sleep(until: start + .milliseconds(Int(total * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.onCycleEnd()
        }
        if landing {
            // Set down: a small hop as it lands.
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [PixelShelf.unit * 3, 0, PixelShelf.unit, 0]
            hop.keyTimes = [0, 0.45, 0.7, 1]
            hop.duration = 0.35
            hop.isAdditive = true
            cat.add(hop, forKey: "hop")
        }
    }
}
