import SwiftUI

struct QueuedView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    let bookID: UUID

    private var book: BookProject? { libraryStore.book(id: bookID) }
    private var position: Int? {
        pipelineController.queuedBookIDs.firstIndex(of: bookID).map { $0 + 1 }
    }

    var body: some View {
        if let book {
            VStack(spacing: 26) {
                // On the pile: the book waits on top of a small stack.
                ZStack(alignment: .bottom) {
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.12)).frame(width: 170, height: 16)
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(width: 182, height: 18)
                    }
                    BookCoverView(book: book, width: 150)
                        .rotationEffect(.degrees(-3))
                        .offset(y: -36)
                }
                .padding(.top, 40)
                VStack(spacing: 8) {
                    Text("Auf dem Stapel")
                        .flowFont(.caption, weight: .semibold)
                        .foregroundStyle(.tint)
                        .textCase(.uppercase)
                        .tracking(1.1)
                    Text(book.title)
                        .appFont(size: 26, weight: .semibold, design: .serif)
                        .multilineTextAlignment(.center)
                    if let position {
                        Text("Platz \(position) von \(pipelineController.queuedBookIDs.count) — wird danach automatisch eingesprochen")
                            .flowFont(.body)
                            .foregroundStyle(.secondary)
                    }
                    if let activeID = pipelineController.activeBookID, let activeBook = libraryStore.book(id: activeID) {
                        Label("Gerade in der Werkstatt: \(activeBook.title)", systemImage: "hammer")
                            .flowFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) {
                    pipelineController.cancelProcessing(bookID: bookID)
                } label: {
                    Label("Vom Stapel nehmen", systemImage: "xmark")
                }
                .buttonStyle(FlowButtonStyle(variant: .destructive))
                Spacer()
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(book.title)
        } else {
            EmptyStateCard(systemImage: "questionmark.folder", title: "Buch nicht gefunden")
        }
    }
}
