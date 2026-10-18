import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    @Binding var selection: SidebarSelection?
    var importingFiles: [String] = []
    var onImport: ([URL]) -> Void

    @State private var showFileImporter = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Übersicht & Import", systemImage: "house")
                    .tag(SidebarSelection.home)
                ForEach(importingFiles, id: \.self) { name in
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).lineLimit(1)
                            Text("Wird eingelesen …").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Bibliothek") {
                ForEach(libraryStore.books.sorted(by: { $0.createdAt > $1.createdAt })) { book in
                    BookRow(
                        book: book,
                        isRunning: pipelineController.isRunning(book.id),
                        progress: pipelineController.progress[book.id],
                        queuePosition: pipelineController.queuedBookIDs.firstIndex(of: book.id).map { $0 + 1 }
                    )
                        .tag(SidebarSelection.book(book.id))
                        .contextMenu {
                            Button("Aus Bibliothek entfernen", role: .destructive) {
                                pipelineController.cancelProcessing(bookID: book.id)
                                libraryStore.remove(book)
                                // The chapter audio was only ever the (now
                                // compressed) intermediate basis — the
                                // finished audiobook lives on in the output
                                // folder. It must not orphan on disk.
                                ChapterAudioStore.removeChapterAudio(bookID: book.id)
                                if selection == .book(book.id) { selection = nil }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Importieren", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .epub].compactMap { $0 }, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                onImport(urls)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                selection = .settings
            } label: {
                Label("Einstellungen", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
            .background(.thinMaterial)
        }
    }
}

private struct BookRow: View {
    let book: BookProject
    let isRunning: Bool
    let progress: RunProgress?
    let queuePosition: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                    .lineLimit(1)
                if isRunning, let progress {
                    Text("\(progress.stage.displayName) · \(Int((progress.overallFraction * 100).rounded())) %\(progress.estimatedTotalRemainingSeconds.map { " · noch " + DurationFormatter.short($0) } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    ProgressView(value: progress.overallFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                } else if let stage = book.currentStage, isRunning {
                    Text(stage.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let queuePosition {
                    Text("Warteschlange: Platz \(queuePosition)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !book.author.isEmpty {
                    Text(book.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isRunning && progress == nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch book.status {
        case .needsReview: return "doc.text"
        case .queued: return "clock.arrow.circlepath"
        case .processing: return "waveform"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch book.status {
        case .needsReview: return .secondary
        case .queued: return .secondary
        case .processing: return .accentColor
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

import UniformTypeIdentifiers
private extension UTType {
    static var epub: UTType { UTType(filenameExtension: "epub") ?? .data }
}
