import SwiftUI
import AppKit

/// "Neu vertonen" (v4): pick another voice for a finished book, listen to
/// it reading a passage of THIS book, and render the book again. Text,
/// summaries and image descriptions are kept (a new summary is optional);
/// the old audio is replaced only once the new narration is complete.
struct RevoiceSheet: View {
    let bookID: UUID

    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PipelineController.self) private var pipelineController
    @Environment(\.dismiss) private var dismiss

    @State private var selected: VoiceID?
    @State private var resummarize = false
    @State private var startFailed = false

    private var book: BookProject? { libraryStore.book(id: bookID) }

    var body: some View {
        VStack(spacing: 0) {
            if let book {
                header(book)
                Divider().opacity(0.4)
                VoiceGalleryView(
                    onSelect: { selected = $0 },
                    currentVoice: selected ?? VoiceID(engine: book.engineID, voice: book.voice),
                    languageCode: book.outputLanguageCode,
                    previewText: Self.previewPassage(of: book, settings: settingsStore.settings),
                    dismissOnSelect: false,
                    embedded: true
                )
                Divider().opacity(0.4)
                footer(book)
            } else {
                Text("Buch nicht gefunden.").padding(40)
            }
        }
        .resizableSheet(preferred: CGSize(width: 900, height: 760), floor: CGSize(width: 520, height: 440))
        .background { PaperPage() }
    }

    private func header(_ book: BookProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: L("„%@“ neu vertonen"), book.title))
                .appFont(size: 22, weight: .semibold, design: .serif)
                .lineLimit(2)
            Text("Text, Zusammenfassungen und Bildbeschreibungen bleiben erhalten. Die bisherige Fassung wird erst ersetzt, wenn die neue vollständig fertig ist — bei Abbruch bleibt sie unverändert. Hörproben lesen einen Abschnitt aus diesem Buch.")
                .flowFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func footer(_ book: BookProject) -> some View {
        let current = VoiceID(engine: book.engineID, voice: book.voice)
        let choice = selected ?? current
        let busy = pipelineController.activeBookID == book.id || pipelineController.queuedBookIDs.contains(book.id)
        let changed = choice != current || resummarize
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                let name = VoiceCatalog.profile(for: choice)?.displayName ?? choice.voice
                Text(verbatim: "\(name) · \(choice.engine.shortName)").flowFont(.callout, weight: .semibold)
                if book.mode == .summary {
                    Toggle(isOn: $resummarize) {
                        Text("Zusammenfassung neu berechnen (KI)").flowFont(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
                if busy {
                    Text("Dieses Buch wird gerade verarbeitet.").flowFont(.caption).foregroundStyle(.orange)
                } else if startFailed {
                    Text("Konnte nicht gestartet werden.").flowFont(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Abbrechen") { dismiss() }
                .buttonStyle(FlowButtonStyle(variant: .subtle, size: .regular))
                .keyboardShortcut(.cancelAction)
            Button("Neu vertonen") {
                let started = pipelineController.revoice(bookID: book.id, engine: choice.engine, voice: choice.voice,
                                                         speed: settingsStore.settings.defaultSpeed(for: choice.engine),
                                                         resummarize: resummarize)
                if started { dismiss() } else { startFailed = true }
            }
            .buttonStyle(.flowProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!changed || busy)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /// A few sentences from the first real chapter, as they will be spoken.
    static func previewPassage(of book: BookProject, settings: AppSettings) -> String? {
        for chapter in book.sortedChapters where chapter.includeInNarration != false {
            let text = PipelineController.spokenText(for: chapter, book: book, settings: settings)
            let sentences = SentenceSplitter.split(text).filter { $0.count > 30 }
            if sentences.count >= 2 { return sentences.prefix(3).joined(separator: " ") }
        }
        return nil
    }
}
