import SwiftUI

/// Interactive chapter-boundary editor. Opens as a sheet from ReviewView,
/// either for the whole book (📖 button) or for a single chapter
/// ("Kapitel teilen …" context menu).
///
/// **Overview mode** shows a colored timeline bar and a grid of chapter
/// cards — each card previews its text and is clickable to zoom in.
///
/// **Detail mode** (zoomed into one chapter) shows every paragraph with
/// clickable split-insertion points between them, plus existing boundary
/// markers that can be renamed or removed.
struct ChapterSplitEditorView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(\.dismiss) private var dismiss

    let bookID: UUID
    /// `nil` → edit the whole book's chapter structure.
    /// Non-nil → split only that single chapter into sub-chapters.
    let targetChapterID: UUID?

    // MARK: - State

    @State private var paragraphs: [String] = []
    /// Paragraph indices where chapters start (always includes 0).
    @State private var splitIndices: [Int] = []
    @State private var chapterTitles: [Int: String] = [:]
    /// Snapshot taken on open for "Zurücksetzen".
    @State private var originalSplitIndices: [Int] = []
    @State private var originalChapterTitles: [Int: String] = [:]
    /// `nil` → overview, otherwise the index into `editorChapters`.
    @State private var selectedChapterIdx: Int? = nil
    /// Hover feedback for the subtle split-insertion points.
    @State private var hoveredInsertionIndex: Int? = nil

    // MARK: - Convenience

    private var book: BookProject {
        libraryStore.book(id: bookID) ?? BookProject(
            title: "", author: "", sourceType: .pdf,
            sourceURL: URL(fileURLWithPath: "/"), chapters: [],
            outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1.0
        )
    }

    private var sortedSplits: [Int] { splitIndices.sorted() }

    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink,
        .teal, .indigo, .mint, .cyan, .brown,
    ]

    // MARK: - Derived chapter list

    struct EditorChapter: Identifiable {
        let id: Int          // index
        let splitStart: Int  // first paragraph index
        let splitEnd: Int    // one-past-last paragraph index
        let title: String
        let characterCount: Int
        let color: Color
    }

    private var editorChapters: [EditorChapter] {
        let sorted = sortedSplits
        return sorted.enumerated().map { index, start in
            let end = index + 1 < sorted.count ? sorted[index + 1] : paragraphs.count
            let chars = paragraphs[start..<end].reduce(0) { $0 + $1.count }
            let fallbackTitle = paragraphs.indices.contains(start) ? ChapterHeadingHeuristic.titleFromFirstWords(paragraphs[start]) : "Kapitel \(index + 1)"
            return EditorChapter(
                id: index,
                splitStart: start,
                splitEnd: end,
                title: chapterTitles[start] ?? fallbackTitle,
                characterCount: chars,
                color: Self.palette[index % Self.palette.count]
            )
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let idx = selectedChapterIdx, idx < editorChapters.count {
                    detailView(for: editorChapters[idx])
                } else {
                    overviewView
                }
            }
            .navigationTitle(targetChapterID != nil
                             ? "Kapitel aufteilen"
                             : "Kapitelstruktur bearbeiten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                if selectedChapterIdx == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Übernehmen") { applyChanges() }
                    }
                }
            }
        }
        .onAppear { loadFromBook() }
        .resizableSheet(preferred: CGSize(width: 900, height: 660), floor: CGSize(width: 640, height: 480))
        .background { PaperPage() }
    }

    // =========================================================================
    // MARK: - Overview
    // =========================================================================

    private var overviewView: some View {
        VStack(spacing: 0) {
            interactiveTimeline.padding()
            Divider()
            actionBar
            Divider()
            chapterCardsGrid
        }
    }

    // MARK: Timeline

    private var interactiveTimeline: some View {
        GeometryReader { geo in
            let totalChars = max(editorChapters.reduce(0) { $0 + $1.characterCount }, 1)
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(max(editorChapters.count - 1, 0))
            let available = max(geo.size.width - totalSpacing, 0)

            HStack(spacing: spacing) {
                ForEach(editorChapters) { ch in
                    let w = max(available * CGFloat(ch.characterCount) / CGFloat(totalChars), 6)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ch.color.opacity(0.7))
                        .frame(width: w)
                        .overlay(
                            Text(ch.title)
                                .appFont(size: 9)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                                .opacity(w > 50 ? 1 : 0)
                        )
                        .onTapGesture { selectedChapterIdx = ch.id }
                        .help("\(ch.title) — \(ch.characterCount) Zeichen")
                }
            }
        }
        .frame(height: 28)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { evenSplit() } label: {
                Label("Gleichmäßig aufteilen", systemImage: "rectangle.split.3x1")
            }
            Button { removeAllSplits() } label: {
                Label("Alle entfernen", systemImage: "xmark.rectangle")
            }
            Button { resetToOriginal() } label: {
                Label("Zurücksetzen", systemImage: "arrow.counterclockwise")
            }
            Spacer()
            Text("\(editorChapters.count) Kapitel")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Chapter cards

    private var chapterCardsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 300))],
                spacing: 12
            ) {
                ForEach(editorChapters) { ch in
                    chapterCard(ch)
                }
            }
            .padding()
        }
    }

    private func chapterCard(_ ch: EditorChapter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(ch.color).frame(width: 10, height: 10)
                Text("Kapitel \(ch.id + 1)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(ch.characterCount) Z.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(ch.title).font(.headline).lineLimit(1)
            Text(paragraphPreview(for: ch))
                .font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }
        .padding(12)
        .background(ch.color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ch.color.opacity(0.25), lineWidth: 1)
        )
        .onTapGesture { selectedChapterIdx = ch.id }
        .contextMenu {
            Button("Kapitelinhalt ansehen …") { selectedChapterIdx = ch.id }
            if editorChapters.count > 1 {
                Button("Kapitelgrenze entfernen", role: .destructive) {
                    removeSplit(at: ch.splitStart)
                }
            }
        }
    }

    private func paragraphPreview(for ch: EditorChapter) -> String {
        let end = min(ch.splitEnd, ch.splitStart + 3)
        guard ch.splitStart < end else { return "" }
        return paragraphs[ch.splitStart..<end]
            .joined(separator: " ")
            .prefix(250)
            .description
    }

    // =========================================================================
    // MARK: - Detail (zoomed) view
    // =========================================================================

    private func detailView(for ch: EditorChapter) -> some View {
        VStack(spacing: 0) {
            detailHeader(for: ch)
            Divider()
            detailParagraphList(for: ch)
        }
    }

    // MARK: Header

    private func detailHeader(for ch: EditorChapter) -> some View {
        HStack {
            Button { selectedChapterIdx = nil } label: {
                Label("Übersicht", systemImage: "chevron.left")
            }
            Spacer()

            if ch.id > 0 {
                Button { selectedChapterIdx = ch.id - 1 } label: {
                    Image(systemName: "chevron.left.2")
                }
            }
            Text("Kapitel \(ch.id + 1) / \(editorChapters.count)")
                .foregroundStyle(.secondary)
            if ch.id < editorChapters.count - 1 {
                Button { selectedChapterIdx = ch.id + 1 } label: {
                    Image(systemName: "chevron.right.2")
                }
            }

            Spacer()
            Text("\(ch.characterCount) Zeichen")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: Paragraph list

    private func detailParagraphList(for ch: EditorChapter) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ch.splitStart..<ch.splitEnd, id: \.self) { pIdx in
                    // Boundary marker (if this paragraph starts a sub-chapter
                    // inside the current view)
                    if splitIndices.contains(pIdx) {
                        chapterBoundaryMarker(at: pIdx)
                    }

                    // Subtle split-insertion button between paragraphs
                    if pIdx > ch.splitStart && !splitIndices.contains(pIdx) {
                        splitInsertionButton(at: pIdx)
                    }

                    // The paragraph itself
                    Text(paragraphs[pIdx])
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: Boundary marker

    private func chapterBoundaryMarker(at pIdx: Int) -> some View {
        let chapterIdx = sortedSplits.firstIndex(of: pIdx) ?? 0
        let color = Self.palette[chapterIdx % Self.palette.count]

        let fallbackTitle = paragraphs.indices.contains(pIdx) ? ChapterHeadingHeuristic.titleFromFirstWords(paragraphs[pIdx]) : "Kapitel \(chapterIdx + 1)"

        return HStack(spacing: 8) {
            Rectangle().fill(color).frame(height: 3)
            Text("✂️")
            TextField(
                "Kapitelname",
                text: bindingForTitle(at: pIdx, fallback: fallbackTitle)
            )
            .textFieldStyle(.plain)
            .font(.caption.bold())
            .foregroundStyle(color)
            .frame(maxWidth: 200)
            Rectangle().fill(color).frame(height: 3)

            if splitIndices.count > 1 {
                Button { removeSplit(at: pIdx) } label: {
                    Image(systemName: "trash")
                        .font(.caption).foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Split insertion button

    private func splitInsertionButton(at pIdx: Int) -> some View {
        Button { addSplit(at: pIdx) } label: {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)
                Image(systemName: "scissors")
                    .appFont(size: 10)
                    .foregroundStyle(.secondary)
                Text("Hier teilen")
                    .appFont(size: 10)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .opacity(hoveredInsertionIndex == pIdx ? 0.9 : 0.25)
        .onHover { hovering in
            hoveredInsertionIndex = hovering ? pIdx : nil
        }
    }

    // =========================================================================
    // MARK: - Actions
    // =========================================================================

    private func addSplit(at pIdx: Int) {
        guard !splitIndices.contains(pIdx) else { return }
        splitIndices.append(pIdx)
        chapterTitles[pIdx] = ChapterHeadingHeuristic.titleFromFirstWords(paragraphs[pIdx])
        renumberAutoTitles()
    }

    private func removeSplit(at pIdx: Int) {
        // Never remove the very last split (there must always be at least one).
        guard splitIndices.count > 1 else { return }
        splitIndices.removeAll { $0 == pIdx }
        chapterTitles.removeValue(forKey: pIdx)
        // If removing a boundary means we're currently zoomed into a chapter
        // index that no longer exists, go back to overview.
        if let sel = selectedChapterIdx, sel >= editorChapters.count {
            selectedChapterIdx = nil
        }
        renumberAutoTitles()
    }

    private func evenSplit() {
        let totalChars = paragraphs.reduce(0) { $0 + $1.count }
        let targetSize = 15000
        let numParts = max(1, Int(round(Double(totalChars) / Double(targetSize))))

        guard numParts > 1 else {
            splitIndices = [0]
            chapterTitles = [0: ChapterHeadingHeuristic.titleFromFirstWords(paragraphs.first ?? "")]
            return
        }

        let targetPerPart = totalChars / numParts
        var newSplits: [Int] = [0]
        var titles: [Int: String] = [0: ChapterHeadingHeuristic.titleFromFirstWords(paragraphs.first ?? "")]
        var accumulated = 0

        for (pIdx, paragraph) in paragraphs.enumerated() {
            accumulated += paragraph.count
            if accumulated >= targetPerPart
                && newSplits.count < numParts
                && pIdx + 1 < paragraphs.count {
                newSplits.append(pIdx + 1)
                titles[pIdx + 1] = ChapterHeadingHeuristic.titleFromFirstWords(paragraphs[pIdx + 1])
                accumulated = 0
            }
        }

        splitIndices = newSplits
        chapterTitles = titles
        selectedChapterIdx = nil
    }

    private func removeAllSplits() {
        splitIndices = [0]
        chapterTitles = [0: book.sortedChapters.first?.title ?? "Gesamtes Dokument"]
        selectedChapterIdx = nil
    }

    private func resetToOriginal() {
        splitIndices = originalSplitIndices
        chapterTitles = originalChapterTitles
        selectedChapterIdx = nil
    }

    private func applyChanges() {
        var updatedBook = book
        let newChapters = buildChapters()

        if let targetID = targetChapterID {
            // Single-chapter split mode: replace that one chapter with N new
            // sub-chapters and shift subsequent orders.
            let sorted = updatedBook.sortedChapters
            guard let targetIdx = sorted.firstIndex(where: { $0.id == targetID }) else { return }
            let targetOrder = sorted[targetIdx].order

            updatedBook.chapters.removeAll { $0.id == targetID }

            var inserted: [UUID] = []
            for (i, var chapter) in newChapters.enumerated() {
                chapter.order = targetOrder + i
                inserted.append(chapter.id)
                updatedBook.chapters.append(chapter)
            }

            let shift = newChapters.count - 1
            if shift > 0 {
                let insertedSet = Set(inserted)
                for i in updatedBook.chapters.indices
                where !insertedSet.contains(updatedBook.chapters[i].id)
                      && updatedBook.chapters[i].order > targetOrder {
                    updatedBook.chapters[i].order += shift
                }
            }
        } else {
            // Full-book mode: replace all chapters.
            updatedBook.chapters = newChapters
        }

        libraryStore.upsert(updatedBook)
        dismiss()
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

    private func buildChapters() -> [Chapter] {
        let sorted = sortedSplits
        return sorted.enumerated().map { index, start in
            let end = index + 1 < sorted.count ? sorted[index + 1] : paragraphs.count
            let text = paragraphs[start..<end].joined(separator: "\n\n")
            let fallbackTitle = paragraphs.indices.contains(start) ? ChapterHeadingHeuristic.titleFromFirstWords(paragraphs[start]) : "Kapitel \(index + 1)"
            let title = chapterTitles[start] ?? fallbackTitle
            return Chapter(title: title, rawText: text, cleanedText: text, order: index)
        }
    }

    private func loadFromBook() {
        if let targetID = targetChapterID,
           let chapter = book.chapters.first(where: { $0.id == targetID }) {
            let parts = chapter.rawText
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            paragraphs = parts.isEmpty ? [chapter.rawText] : parts
            splitIndices = [0]
            chapterTitles = [0: chapter.title]
        } else {
            var allParagraphs: [String] = []
            var splits: [Int] = []
            var titles: [Int: String] = [:]

            for chapter in book.sortedChapters {
                let parts = chapter.rawText
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let start = allParagraphs.count
                splits.append(start)
                titles[start] = chapter.title
                allParagraphs.append(contentsOf: parts.isEmpty ? [chapter.rawText] : parts)
            }

            paragraphs = allParagraphs
            splitIndices = splits.isEmpty ? [0] : splits
            chapterTitles = titles
        }

        originalSplitIndices = splitIndices
        originalChapterTitles = chapterTitles
    }

    private func renumberAutoTitles() {
        // No-op: keep titles derived from text or manually entered by user
    }

    private func bindingForTitle(at splitIndex: Int, fallback: String) -> Binding<String> {
        Binding(
            get: { chapterTitles[splitIndex] ?? fallback },
            set: { chapterTitles[splitIndex] = $0 }
        )
    }
}
