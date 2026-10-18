import SwiftUI

struct BookDetailView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    let bookID: UUID

    var body: some View {
        if let book = libraryStore.book(id: bookID) {
            Group {
                if pipelineController.isRunning(bookID) || book.status == .processing || book.status == .paused {
                    ProcessingView(bookID: bookID)
                } else if book.status == .queued {
                    QueuedView(bookID: bookID)
                } else if book.status == .completed {
                    PlayerView(bookID: bookID)
                } else {
                    ReviewView(bookID: bookID)
                }
            }
            .id(bookID)
        } else {
            ContentUnavailableView("Buch nicht gefunden", systemImage: "questionmark.folder")
        }
    }
}
