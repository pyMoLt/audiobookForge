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
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(book.title).font(.title3.weight(.semibold))
                if let position {
                    Text("Position \(position) von \(pipelineController.queuedBookIDs.count) in der Warteschlange")
                        .foregroundStyle(.secondary)
                }
                if let activeID = pipelineController.activeBookID, let activeBook = libraryStore.book(id: activeID) {
                    Text("Aktuell in Bearbeitung: \(activeBook.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Aus Warteschlange entfernen", role: .destructive) {
                    pipelineController.cancelProcessing(bookID: bookID)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(book.title)
        } else {
            ContentUnavailableView("Buch nicht gefunden", systemImage: "questionmark.folder")
        }
    }
}
