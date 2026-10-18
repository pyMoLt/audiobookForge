import SwiftUI
import AppKit

struct PlayerView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    let bookID: UUID

    @StateObject private var coordinator = AudioPlayerCoordinator()
    @State private var hasLoaded = false
    @State private var showReadAlong = true
    @State private var diffChapter: Chapter?

    private var book: BookProject? { libraryStore.book(id: bookID) }

    var body: some View {
        if let book {
            HSplitView {
                chapterList(book: book)
                    .frame(minWidth: 260, idealWidth: 300)
                playbackArea(book: book)
                    .frame(minWidth: 360)
                if showReadAlong {
                    readAlongPane(book: book)
                        .frame(minWidth: 320, idealWidth: 420)
                }
            }
            .navigationTitle(book.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showReadAlong) {
                        Label("Mitlesen", systemImage: "text.alignleft")
                    }
                    .toggleStyle(.button)
                }
                ToolbarItem(placement: .primaryAction) {
                    if let outputURL = book.outputDirectoryURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        } label: {
                            Label("Im Finder zeigen", systemImage: "folder")
                        }
                    }
                }
            }
            .onAppear { loadIfNeeded(book: book) }
            .onChange(of: book.chapters.map(\.audioStatus)) { oldStatuses, newStatuses in
                guard oldStatuses != newStatuses,
                      zip(oldStatuses, newStatuses).contains(where: { $0.0 != .ready && $0.1 == .ready }) else { return }
                let sorted = book.sortedChapters
                coordinator.reload(chapterURLs: sorted.compactMap(\.audioFileURL), segments: sorted.map { $0.audioSegments ?? [] })
            }
            .sheet(item: $diffChapter) { chapter in
                SummaryDiffView(
                    chapterTitle: chapter.title,
                    originalText: chapter.cleanedText,
                    summaryText: chapter.summarizedText ?? ""
                )
            }
        } else {
            ContentUnavailableView("Buch nicht gefunden", systemImage: "questionmark.folder")
        }
    }

    private func readAlongPane(book: BookProject) -> some View {
        let sorted = book.sortedChapters
        let currentChapter = sorted.indices.contains(coordinator.currentChapterIndex) ? sorted[coordinator.currentChapterIndex] : nil
        return VStack(alignment: .leading, spacing: 0) {
            Text("Mitlesen").font(.subheadline.weight(.semibold)).padding(12)
            Divider()
            if let currentChapter {
                ReadAlongView(
                    fullText: currentChapter.textForNarration,
                    segments: coordinator.currentChapterSegments,
                    currentTime: coordinator.currentTime
                )
            }
        }
        .background(.regularMaterial)
    }

    private func loadIfNeeded(book: BookProject) {
        guard !hasLoaded else { return }
        hasLoaded = true
        let sorted = book.sortedChapters
        let urls = sorted.compactMap(\.audioFileURL)
        let segments = sorted.map { $0.audioSegments ?? [] }
        coordinator.load(chapterURLs: urls, segments: segments)
    }

    private func chapterList(book: BookProject) -> some View {
        List {
            ForEach(Array(book.sortedChapters.enumerated()), id: \.element.id) { index, chapter in
                HStack {
                    Image(systemName: index == coordinator.currentChapterIndex ? "speaker.wave.2.fill" : "circle")
                        .foregroundStyle(index == coordinator.currentChapterIndex ? Color.accentColor : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading) {
                        Text(chapter.title)
                        if let duration = chapter.audioDurationSeconds {
                            Text(formatted(duration)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if book.mode == .summary, chapter.summarizedText != nil {
                        Button {
                            diffChapter = chapter
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .help("Original mit Zusammenfassung vergleichen")
                    }
                    Button {
                        pipelineController.regenerateChapter(bookID: bookID, chapterID: chapter.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Dieses Kapitel neu generieren")
                    .disabled(pipelineController.isAnyBookActive)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    coordinator.playChapter(at: index)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
    }

    private func playbackArea(book: BookProject) -> some View {
        VStack(spacing: 24) {
            Spacer()

            if let coverData = book.coverImageData, let image = NSImage(data: coverData) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 8)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: 200, height: 200)
                    .overlay(Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.secondary))
            }

            VStack(spacing: 4) {
                Text(book.sortedChapters.indices.contains(coordinator.currentChapterIndex) ? book.sortedChapters[coordinator.currentChapterIndex].title : book.title)
                    .font(.title3.weight(.semibold))
                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let segmentText = coordinator.currentSegmentText {
                    Text(segmentText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, 4)
                        .frame(maxWidth: 420)
                }
            }

            VStack(spacing: 8) {
                Slider(value: Binding(get: { coordinator.currentTime }, set: { coordinator.seek(to: $0) }), in: 0...(max(coordinator.duration, 1)))
                HStack {
                    Text(formatted(coordinator.currentTime)).font(.caption).monospacedDigit()
                    Spacer()
                    Text(formatted(coordinator.duration)).font(.caption).monospacedDigit()
                }
            }
            .frame(maxWidth: 400)

            HStack(spacing: 28) {
                Button { coordinator.previousChapter() } label: {
                    Image(systemName: "backward.end.fill")
                }
                Button { coordinator.togglePlayPause() } label: {
                    Image(systemName: coordinator.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                Button { coordinator.nextChapter() } label: {
                    Image(systemName: "forward.end.fill")
                }
            }
            .buttonStyle(.plain)
            .font(.title2)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
