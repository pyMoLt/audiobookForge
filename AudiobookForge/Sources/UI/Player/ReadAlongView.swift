import SwiftUI

// MARK: - Paragraph layout (pure, testable)

/// Groups the narrated sentences (TTS segments) back into the paragraphs
/// of the chapter text. Before, every sentence was its own block — a list
/// of lines with big gaps instead of a readable page (audit).
enum ReadAlongLayout {
    struct Paragraph: Identifiable, Equatable, Sendable {
        let id: Int
        var segments: [TTSSegment]
    }

    /// Paragraph breaks are taken from line breaks in `fullText` between
    /// two consecutive sentences. Without any break (flat text) paragraphs
    /// are cut every `fallbackLength` sentences so the page still breathes.
    static func paragraphs(fullText: String, segments: [TTSSegment], fallbackLength: Int = 6) -> [Paragraph] {
        let usable = segments.filter { !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }
        var result: [Paragraph] = []
        var current: [TTSSegment] = []
        var cursor = fullText.startIndex
        var sawAnyBreak = false

        for segment in usable {
            let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let probe = String(text.prefix(24))
            var breakBefore = false
            if !probe.isEmpty, cursor < fullText.endIndex,
               let range = fullText.range(of: probe, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<fullText.endIndex) {
                let gap = fullText[cursor..<range.lowerBound]
                breakBefore = gap.contains("\n")
                cursor = fullText.index(range.lowerBound, offsetBy: min(text.count, fullText.distance(from: range.lowerBound, to: fullText.endIndex)))
            }
            if breakBefore { sawAnyBreak = true }
            if breakBefore, !current.isEmpty {
                result.append(Paragraph(id: result.count, segments: current))
                current = []
            }
            current.append(segment)
        }
        if !current.isEmpty { result.append(Paragraph(id: result.count, segments: current)) }

        guard !sawAnyBreak, result.count == 1, usable.count > fallbackLength else { return result }
        return stride(from: 0, to: usable.count, by: fallbackLength).enumerated().map { offset, start in
            Paragraph(id: offset, segments: Array(usable[start..<min(start + fallbackLength, usable.count)]))
        }
    }

    /// Segments with text for every sentence. Engines like Kokoro report
    /// timing chunks that don't line up 1:1 with our sentence split (their
    /// `text` is then nil). We spread the chapter's sentences over the
    /// measured speech chunks by character share — speech rate is nearly
    /// constant, so highlight, auto-scroll and tap-to-seek stay usable.
    static func alignedSegments(fullText: String, timing: [TTSSegment]) -> [TTSSegment] {
        guard !timing.isEmpty else { return [] }
        if timing.allSatisfy({ !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            // Exact chunk text from the engine (v3.1 bridge): split each
            // chunk into sentences and spread its own duration over them.
            var result: [TTSSegment] = []
            for chunk in timing.sorted(by: { $0.startSeconds < $1.startSeconds }) {
                let sentences = SentenceSplitter.split(chunk.text ?? "").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard sentences.count > 1 else {
                    result.append(TTSSegment(index: result.count, startSeconds: chunk.startSeconds, durationSeconds: chunk.durationSeconds, text: chunk.text))
                    continue
                }
                let total = Double(sentences.reduce(0) { $0 + max(1, $1.count) })
                var offset = 0.0
                for sentence in sentences {
                    let share = Double(max(1, sentence.count)) / total * chunk.durationSeconds
                    result.append(TTSSegment(index: result.count, startSeconds: chunk.startSeconds + offset, durationSeconds: share, text: sentence))
                    offset += share
                }
            }
            return result
        }
        // Older runs (no chunk text): the engines speak one planned
        // segment (pause planner) per chunk — same count → exact pairing.
        let planned = PausePlanner.plan(fullText).map(\.text)
        if planned.count == timing.count {
            let sorted = timing.sorted { $0.startSeconds < $1.startSeconds }
            let withText = zip(sorted, planned).map { TTSSegment(index: $0.index, startSeconds: $0.startSeconds, durationSeconds: $0.durationSeconds, text: $1) }
            return alignedSegments(fullText: fullText, timing: withText)
        }
        // Otherwise line breaks (Kokoro splits at newlines).
        let lines = fullText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count == timing.count {
            let sorted = timing.sorted { $0.startSeconds < $1.startSeconds }
            let withText = zip(sorted, lines).map { TTSSegment(index: $0.index, startSeconds: $0.startSeconds, durationSeconds: $0.durationSeconds, text: $1) }
            return alignedSegments(fullText: fullText, timing: withText)
        }
        let sentences = SentenceSplitter.split(fullText).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !sentences.isEmpty else { return [] }
        let chunks = timing.sorted { $0.startSeconds < $1.startSeconds }
        let speech = chunks.reduce(0) { $0 + max(0, $1.durationSeconds) }
        let totalChars = Double(sentences.reduce(0) { $0 + max(1, $1.count) })
        guard speech > 0, totalChars > 0 else { return [] }

        /// Speech position (seconds of pure speech) → chapter time.
        func time(atSpeech position: Double) -> Double {
            var accumulated = 0.0
            for chunk in chunks {
                let d = max(0, chunk.durationSeconds)
                if position <= accumulated + d { return chunk.startSeconds + (position - accumulated) }
                accumulated += d
            }
            return (chunks.last.map { $0.startSeconds + $0.durationSeconds }) ?? 0
        }

        var result: [TTSSegment] = []
        var chars = 0.0
        for (index, sentence) in sentences.enumerated() {
            let start = time(atSpeech: chars / totalChars * speech)
            chars += Double(max(1, sentence.count))
            let end = time(atSpeech: chars / totalChars * speech)
            result.append(TTSSegment(index: index, startSeconds: start, durationSeconds: max(0.05, end - start), text: sentence))
        }
        return result
    }

    /// Index of the segment playing at `time` (chapter-relative).
    static func segmentIndex(at time: Double, in segments: [TTSSegment]) -> Int? {
        segments.last { $0.startSeconds <= time + 0.05 }?.index
    }

    /// Plain paragraphs for chapters without timing data.
    static func plainParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Reader page

/// The read-along text as a book page: serif type, comfortable measure,
/// the spoken sentence softly highlighted. Click any sentence to jump
/// there; scrolling away pauses auto-follow until "Zur aktuellen Stelle".
/// Other chapters can be read ahead/back without changing playback.
struct ReaderPane: View {
    let book: BookProject
    /// Not observed here: a tiny tracker view watches the 4 Hz playback
    /// clock and only pushes changes of chapter / spoken sentence — the
    /// page re-renders a few times per minute instead of 4× per second.
    let coordinator: AudioPlayerCoordinator
    @State private var playingChapter = 0
    @State private var spokenIndex: Int?

    @AppStorage("reader.textSize") private var textSize: Double = 17
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PlaybackSession.self) private var playback
    @Environment(LibraryStore.self) private var libraryStore
    @State private var displayedChapter: Int?
    @State private var follow = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.flowAccent) private var accent

    private var chapters: [Chapter] { book.sortedChapters }
    private var chapterIndex: Int { displayedChapter ?? playingChapter }
    private var isShowingCurrent: Bool { chapterIndex == playingChapter }
    private var chapter: Chapter? { chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil }

    /// Sentence/paragraph layout of the shown chapter. Computed ONCE per
    /// chapter off the main thread — before, every 0.25 s playback tick
    /// re-split the whole chapter (99 % CPU while reading, measured).
    @State private var layout = ReaderLayout.empty

    private var segments: [TTSSegment] { layout.segments }

    /// The player's live data belongs to THIS book only once it has
    /// loaded it — right after switching books it still holds the previous
    /// one's segments (their text showed up under the new title).
    private var playerHasThisBook: Bool { playback.bookID == book.id }

    private var timing: [TTSSegment] {
        isShowingCurrent && playerHasThisBook && !coordinator.currentChapterSegments.isEmpty
            ? coordinator.currentChapterSegments
            : (chapter?.audioSegments ?? [])
    }

    private var layoutKey: String {
        "\(book.id.uuidString)|\(chapter?.id.uuidString ?? "-")|\(timing.count)|\(timing.first?.text?.prefix(24) ?? "")"
    }

    /// Sentence being spoken right now (binary search on cached starts).
    private var currentIndex: Int? {
        isShowingCurrent ? spokenIndex : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            ZStack(alignment: .bottom) {
                page
                if !follow || !isShowingCurrent {
                    Button {
                        withAnimation(Theme.Motion.flow) {
                            displayedChapter = nil
                            follow = true
                        }
                    } label: {
                        Label("Zur aktuellen Stelle", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .flowFont(.callout, weight: .semibold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background { paper }
        .background {
            if playerHasThisBook {
                PlaybackTracker(coordinator: coordinator, layout: layout, chapter: $playingChapter, sentence: $spokenIndex)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.5), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 16, y: 6)
        .animation(Theme.Motion.flow, value: follow)
        .animation(Theme.Motion.flow, value: isShowingCurrent)
        .onChange(of: playingChapter) { _, _ in
            if follow { displayedChapter = nil }
        }
    }

    /// Warm paper, a soft spine shadow on the left edge.
    private var paper: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(colorScheme == .dark
                             ? Color(red: 0.11, green: 0.105, blue: 0.10).opacity(0.86)
                             : Color(red: 0.995, green: 0.985, blue: 0.962).opacity(0.9))
            LinearGradient(colors: [Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 26)
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 10) {
            Button {
                turn(by: -1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(chapterIndex <= 0)
            .help("Vorheriges Kapitel lesen (Wiedergabe läuft weiter)")

            Text(chapters.isEmpty ? "" : "Kapitel \(chapterIndex + 1) von \(chapters.count)")
                .flowFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
                .monospacedDigit()

            Button {
                turn(by: 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(chapterIndex >= chapters.count - 1)
            .help("Nächstes Kapitel lesen (Wiedergabe läuft weiter)")

            Spacer()

            HStack(spacing: 2) {
                Button { textSize = max(13, textSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller").frame(width: 28, height: 26)
                }
                .help("Schrift kleiner")
                Button { textSize = min(28, textSize + 1) } label: {
                    Image(systemName: "textformat.size.larger").frame(width: 28, height: 26)
                }
                .help("Schrift größer")
            }
            .buttonStyle(PressableStyle())
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: textSize * 0.9) {
                    chapterHeading
                    if layout.paragraphs.isEmpty {
                        ForEach(Array(layout.plain.enumerated()), id: \.offset) { _, text in
                            Text(text)
                                .appFont(size: textSize, design: .serif)
                                .lineSpacing(textSize * 0.42)
                                .textSelection(.enabled)
                        }
                    } else {
                        let current = currentIndex
                        let currentStart = current.flatMap { layout.start(of: $0) }
                        ForEach(layout.paragraphs) { paragraph in
                            ParagraphText(
                                paragraph: paragraph,
                                state: ParagraphText.state(for: paragraph, current: current, currentStart: currentStart),
                                textSize: textSize,
                                highlight: accent.color.opacity(colorScheme == .dark ? 0.32 : 0.18),
                                isDark: colorScheme == .dark
                            )
                            .equatable()
                            .id(paragraph.id)
                        }
                    }
                    Text("❦")
                        .appFont(size: 20, design: .serif)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.top, 8)
                .padding(.bottom, 70)
                .frame(maxWidth: .infinity)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "abf-seek", let index = Int(url.host() ?? ""),
                          let segment = segments.first(where: { $0.index == index }) else { return .systemAction }
                    coordinator.seek(chapter: chapterIndex, to: segment.startSeconds + 0.01)
                    if !coordinator.isPlaying { coordinator.play() }
                    withAnimation(Theme.Motion.flow) {
                        displayedChapter = nil
                        follow = true
                    }
                    return .handled
                })
            }
            .scrollIndicators(.never)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { follow = false }
            }
            .onChange(of: currentIndex.flatMap { layout.paragraphID(containing: $0) }) { _, paragraphID in
                guard follow, isShowingCurrent, let paragraphID else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(paragraphID, anchor: UnitPoint(x: 0.5, y: 0.35))
                }
            }
            .task(id: layoutKey) {
                // The library hands out books without chapter text until
                // first use — load the full book if this chapter is empty.
                var source = book
                if let current = chapter, current.cleanedText.isEmpty, current.summarizedText == nil,
                   let full = libraryStore.book(id: book.id) {
                    source = full
                }
                let sourceChapter = source.sortedChapters.indices.contains(chapterIndex) ? source.sortedChapters[chapterIndex] : chapter
                // Same text the engine spoke → exact sentence pairing.
                let spoken = sourceChapter.map { PipelineController.spokenText(for: $0, book: source, settings: settingsStore.settings) }
                let text = (spoken?.isEmpty == false ? spoken : sourceChapter?.textForNarration) ?? ""
                let timing = self.timing
                let key = layoutKey
                let built = await Task.detached(priority: .userInitiated) {
                    ReaderLayout.build(text: text, timing: timing)
                }.value
                // A slower build for the previous book/chapter must not
                // overwrite the current one (it did: Christmas Carol text
                // under The Time Machine after switching books).
                guard !Task.isCancelled, key == layoutKey else { return }
                layout = built
            }
            .onChange(of: chapterIndex) { _, _ in
                proxy.scrollTo("top", anchor: .top)
            }
        }
    }

    private var chapterHeading: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let group = chapter?.groupTitle, !group.isEmpty, group != chapter?.title {
                Text(group)
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                    .tracking(1.2)
            }
            Text(chapter?.title ?? book.title)
                .appFont(size: textSize * 1.65, weight: .semibold, design: .serif)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Rectangle().fill(accent.color).frame(width: 34, height: 2)
                if let duration = chapter?.audioDurationSeconds {
                    Text(ListeningTimeFormatter.long(duration))
                        .flowFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 10)
        .id("top")
    }

    private func turn(by delta: Int) {
        let target = min(max(chapterIndex + delta, 0), max(chapters.count - 1, 0))
        withAnimation(Theme.Motion.flow) {
            displayedChapter = target == playingChapter ? nil : target
            follow = target == playingChapter
        }
    }
}

/// Watches the playback clock (4 Hz) and forwards only meaningful changes.
private struct PlaybackTracker: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator
    let layout: ReaderLayout
    @Binding var chapter: Int
    @Binding var sentence: Int?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: coordinator.currentChapterIndex, initial: true) { _, value in
                if chapter != value { chapter = value }
            }
            .onChange(of: coordinator.currentTime, initial: true) { _, _ in update() }
            .onChange(of: layout.segments.count) { _, _ in update() }
    }

    private func update() {
        let index = layout.index(at: coordinator.chapterElapsed)
        if sentence != index { sentence = index }
    }
}

/// Cached reading layout of one chapter (sentences with timing, paragraphs).
struct ReaderLayout: Sendable {
    var segments: [TTSSegment]
    var paragraphs: [ReadAlongLayout.Paragraph]
    var plain: [String]
    private var starts: [Double]
    private var indexes: [Int]
    private var paragraphOfIndex: [Int: Int]

    static let empty = ReaderLayout(segments: [], paragraphs: [], plain: [], starts: [], indexes: [], paragraphOfIndex: [:])

    static func build(text: String, timing: [TTSSegment]) -> ReaderLayout {
        let segments = ReadAlongLayout.alignedSegments(fullText: text, timing: timing)
        let paragraphs = ReadAlongLayout.paragraphs(fullText: text, segments: segments)
        let sorted = segments.sorted { $0.startSeconds < $1.startSeconds }
        var paragraphOfIndex: [Int: Int] = [:]
        for paragraph in paragraphs {
            for segment in paragraph.segments { paragraphOfIndex[segment.index] = paragraph.id }
        }
        return ReaderLayout(
            segments: segments,
            paragraphs: paragraphs,
            plain: paragraphs.isEmpty ? ReadAlongLayout.plainParagraphs(text) : [],
            starts: sorted.map(\.startSeconds),
            indexes: sorted.map(\.index),
            paragraphOfIndex: paragraphOfIndex
        )
    }

    /// Segment index playing at `time` — O(log n).
    func index(at time: Double) -> Int? {
        var low = 0, high = starts.count - 1, result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= time + 0.05 { result = indexes[mid]; low = mid + 1 } else { high = mid - 1 }
        }
        return result
    }

    func start(of index: Int) -> Double? {
        segments.first { $0.index == index }?.startSeconds
    }

    func paragraphID(containing index: Int) -> Int? { paragraphOfIndex[index] }
}

/// One paragraph of the reader page. Equatable on its visual state, so a
/// playback tick only re-renders the paragraph whose sentence changed.
struct ParagraphText: View, Equatable {
    enum State: Equatable { case past, future, current(Int), mixed(currentStart: Double) }

    let paragraph: ReadAlongLayout.Paragraph
    let state: State
    let textSize: Double
    let highlight: Color
    let isDark: Bool

    static func state(for paragraph: ReadAlongLayout.Paragraph, current: Int?, currentStart: Double?) -> State {
        guard let currentStart else { return .future }
        if let current, paragraph.segments.contains(where: { $0.index == current }) { return .current(current) }
        let last = paragraph.segments.last?.startSeconds ?? 0
        let first = paragraph.segments.first?.startSeconds ?? 0
        if last < currentStart { return .past }
        if first >= currentStart { return .future }
        return .mixed(currentStart: currentStart)
    }

    var body: some View {
        Text(attributed)
            .appFont(size: textSize, design: .serif)
            .lineSpacing(textSize * 0.42)
            .tint(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let currentIndex: Int? = { if case .current(let i) = state { return i } else { return nil } }()
        let currentStart: Double? = {
            switch state {
            case .current(let i): return paragraph.segments.first { $0.index == i }?.startSeconds
            case .mixed(let start): return start
            case .past: return .infinity
            case .future: return nil
            }
        }()
        for segment in paragraph.segments {
            var run = AttributedString((segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + " ")
            run.link = URL(string: "abf-seek://\(segment.index)")
            if segment.index == currentIndex {
                run.backgroundColor = highlight
                run.foregroundColor = isDark ? Color.white : Color.black
            } else if let currentStart, segment.startSeconds < currentStart {
                run.foregroundColor = Color.primary.opacity(0.55)
            } else {
                run.foregroundColor = Color.primary.opacity(0.92)
            }
            result += run
        }
        return result
    }
}

// MARK: - Table of contents

/// The chapter list as a book's table of contents: group headings in small
/// caps, dotted leaders to the duration, a bookmark ribbon at the current
/// chapter. Row actions (compare summary, regenerate) appear on hover.
struct ChapterListPane: View {
    let book: BookProject
    /// Observed only through `ChapterIndexTracker` / `ChapterProgressLine`
    /// so the list doesn't rebuild on every playback tick.
    let coordinator: AudioPlayerCoordinator
    @State private var currentChapter = 0
    var onDiff: (Chapter) -> Void
    @Environment(PipelineController.self) private var pipelineController
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inhalt")
                .appFont(size: 22, weight: .semibold, design: .serif)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let chapters = book.sortedChapters
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            if let group = chapter.groupTitle, !group.isEmpty,
                               index == 0 || chapters[index - 1].groupTitle != group {
                                Text(group)
                                    .flowFont(.caption, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.8)
                                    .padding(.horizontal, 20)
                                    .padding(.top, index == 0 ? 2 : 14)
                                    .padding(.bottom, 4)
                            }
                            row(index: index, chapter: chapter)
                                .id(chapter.id)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.never)
                .onAppear { scrollToCurrent(proxy) }
                .onChange(of: currentChapter) { _, _ in
                    withAnimation(Theme.Motion.flow) { scrollToCurrent(proxy) }
                }
            }
        }
        .flowSurface(cornerRadius: Theme.Radius.panel)
        .background { ChapterIndexTracker(coordinator: coordinator, chapter: $currentChapter) }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        let chapters = book.sortedChapters
        guard chapters.indices.contains(currentChapter) else { return }
        proxy.scrollTo(chapters[currentChapter].id, anchor: .center)
    }

    private func row(index: Int, chapter: Chapter) -> some View {
        let isCurrent = index == currentChapter
        let isPast = index < currentChapter
        let isHovered = hovered == chapter.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                if isCurrent {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(index + 1)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .flowFont(.caption, weight: .semibold)
            .frame(width: 22, alignment: .trailing)

            Text(chapter.title)
                .flowFont(.body, weight: isCurrent ? .semibold : .regular)
                .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .layoutPriority(1)

            DottedLeader()
                .frame(minWidth: 10)

            if isHovered {
                HStack(spacing: 2) {
                    if book.mode == .summary, chapter.summarizedText != nil {
                        Button { onDiff(chapter) } label: {
                            Image(systemName: "arrow.left.arrow.right").frame(width: 22, height: 20)
                        }
                        .help("Original mit Zusammenfassung vergleichen")
                    }
                    Button {
                        pipelineController.regenerateChapter(bookID: book.id, chapterID: chapter.id)
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 22, height: 20)
                    }
                    .help("Dieses Kapitel neu generieren")
                    .disabled(pipelineController.isAnyBookActive)
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.secondary)
                .transition(.opacity)
            } else if let duration = chapter.audioDurationSeconds {
                Text(ListeningTimeFormatter.clock(duration))
                    .flowFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.0))
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isCurrent {
                ChapterProgressLine(coordinator: coordinator)
                    .padding(.leading, 42)
                    .padding(.trailing, 12)
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.quick) { hovered = inside ? chapter.id : (hovered == chapter.id ? nil : hovered) } }
        .onTapGesture { coordinator.playChapter(at: index) }
        .animation(Theme.Motion.flow, value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Kapitel abspielen")
    }
}

private struct ChapterIndexTracker: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator
    @Binding var chapter: Int
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: coordinator.currentChapterIndex, initial: true) { _, value in
                if chapter != value { chapter = value }
            }
    }
}

/// Thin progress line under the current chapter (the only part that ticks).
private struct ChapterProgressLine: View {
    @ObservedObject var coordinator: AudioPlayerCoordinator
    var body: some View {
        FlowProgressBar(fraction: coordinator.chapterDuration > 0 ? coordinator.chapterElapsed / coordinator.chapterDuration : 0, height: 2.5)
    }
}

/// "Title ........ 12:34" — the leader of a printed table of contents.
struct DottedLeader: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height - 1))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height - 1))
            }
            .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 4.5]))
        }
        .frame(height: 8)
    }
}
