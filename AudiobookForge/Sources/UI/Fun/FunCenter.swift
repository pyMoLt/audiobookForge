import SwiftUI

/// Small rewards for using the app (v4.3), shown as a retro toast.
enum Achievement: String, CaseIterable, Identifiable, Sendable {
    case firstBook, bookworm, marathon, nightOwl, polyglot, answer42, longNeck, dogLover, secretAgent, konami

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstBook: return L("Erstes Hörbuch")
        case .bookworm: return L("Bücherwurm")
        case .marathon: return L("Marathon")
        case .nightOwl: return L("Nachteule")
        case .polyglot: return L("Polyglott")
        case .answer42: return L("Die Antwort")
        case .longNeck: return L("Sehr langer Hals")
        case .dogLover: return L("Bester Junge")
        case .secretAgent: return L("Zeitreise nach 1998")
        case .konami: return L("↑↑↓↓←→←→BA")
        }
    }

    var detail: String {
        switch self {
        case .firstBook: return L("Dein erstes Hörbuch ist fertig.")
        case .bookworm: return L("Fünf Hörbücher fertiggestellt.")
        case .marathon: return L("Ein Hörbuch mit mehr als 20 Stunden.")
        case .nightOwl: return L("Nach Mitternacht fertig geworden. Schlaf ist überbewertet.")
        case .polyglot: return L("Hörbücher in drei Sprachen.")
        case .answer42: return L("Ein Buch mit genau 42 Kapiteln. Keine Panik.")
        case .longNeck: return L("Ein Buch mit über 500 Kapiteln — der Hund hat es gemerkt.")
        case .dogLover: return L("Den Hund zehnmal gestreichelt.")
        case .secretAgent: return L("Den Pixel-Modus eingeschaltet. Trotz aller Warnungen.")
        case .konami: return L("Den Code eingegeben. Du weißt Bescheid.")
        }
    }

    var systemImage: String {
        switch self {
        case .firstBook: return "book.closed.fill"
        case .bookworm: return "books.vertical.fill"
        case .marathon: return "figure.run"
        case .nightOwl: return "moon.stars.fill"
        case .polyglot: return "globe"
        case .answer42: return "sparkles"
        case .longNeck: return "ruler"
        case .dogLover: return "pawprint.fill"
        case .secretAgent: return "square.grid.3x3.fill"
        case .konami: return "gamecontroller.fill"
        }
    }

    /// Which achievements a finished book earns (pure, testable).
    static func earned(by book: BookProject, completedBooks: [BookProject], at date: Date, calendar: Calendar = .current) -> Set<Achievement> {
        var result: Set<Achievement> = [.firstBook]
        if completedBooks.count >= 5 { result.insert(.bookworm) }
        let seconds = book.chapters.compactMap(\.audioDurationSeconds).reduce(0, +)
        if seconds >= 20 * 3600 { result.insert(.marathon) }
        if calendar.component(.hour, from: date) < 5 { result.insert(.nightOwl) }
        if Set(completedBooks.map { String($0.languageCode.prefix(2)) }).count >= 3 { result.insert(.polyglot) }
        if book.chapters.count == 42 { result.insert(.answer42) }
        if book.chapters.count > 500 { result.insert(.longNeck) }
        return result
    }
}

/// Coordinates the easter eggs (v4.3): achievement toasts, owl post, the
/// pixel-mode confirmation cascade. One instance, owned by the app window.
@MainActor
@Observable
final class FunCenter {
    struct OwlDelivery: Identifiable, Equatable {
        let id = UUID()
        let bookID: UUID
        let title: String
    }

    var toast: Achievement?
    var owlPost: OwlDelivery?
    /// Steps of the "are you sure?" cascade currently open (0 = none).
    var cascadeStep = 0

    @ObservationIgnored private var settingsStore: SettingsStore?
    @ObservationIgnored private var toastQueue: [Achievement] = []

    func attach(_ store: SettingsStore) { settingsStore = store }

    func unlock(_ achievement: Achievement) {
        guard let store = settingsStore, store.settings.unlockedAchievements[achievement.rawValue] == nil else { return }
        store.settings.unlockedAchievements[achievement.rawValue] = Date()
        toastQueue.append(achievement)
        showNextToast()
    }

    private func showNextToast() {
        guard toast == nil, !toastQueue.isEmpty else { return }
        let next = toastQueue.removeFirst()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = next }
        SoundFX.shared.play(.achievement)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeIn(duration: 0.25)) { toast = nil }
            try? await Task.sleep(for: .seconds(0.4))
            showNextToast()
        }
    }

    /// A book is finished: fanfare, owl post, achievements.
    func bookCompleted(_ book: BookProject, library: [BookProject]) {
        guard let store = settingsStore else { return }
        SoundFX.shared.play(.bookDone)
        if store.settings.owlPostEnabled {
            owlPost = OwlDelivery(bookID: book.id, title: book.title)
        }
        let completed = library.filter { $0.status == .completed }
        for achievement in Achievement.earned(by: book, completedBooks: completed, at: Date()).sorted(by: { $0.rawValue < $1.rawValue }) {
            unlock(achievement)
        }
    }

    func petDog() {
        guard let store = settingsStore else { return }
        store.settings.dogPets += 1
        SoundFX.shared.play(store.settings.dogPets % 3 == 0 ? .bark : .pet)
        if store.settings.dogPets >= 10 { unlock(.dogLover) }
    }

    // MARK: Pixel mode cascade

    static let cascadeMessages: [String] = [
        L("Pixel-Modus einschalten? Die ganze App sieht danach aus wie 1998."),
        L("Bist du sicher?"),
        L("Bist du dir WIRKLICH sicher?"),
        L("Wirklich, wirklich sicher? Es gibt kein Zurück.*\n\n*Doch, in den Einstellungen."),
    ]

    func requestPixelMode() {
        guard let store = settingsStore, !store.settings.pixelMode, cascadeStep == 0 else { return }
        cascadeStep = 1
        SoundFX.shared.play(.retroDing)
    }

    func confirmCascadeStep() {
        guard let store = settingsStore else { return }
        if cascadeStep < Self.cascadeMessages.count {
            cascadeStep += 1
            SoundFX.shared.play(.retroDing)
        } else {
            cascadeStep = 0
            store.settings.pixelMode = true
            SoundFX.shared.play(.powerUp)
            unlock(.secretAgent)
        }
    }

    func cancelCascade() { cascadeStep = 0 }

    func konamiEntered() {
        unlock(.konami)
        requestPixelMode()
    }
}

extension Notification.Name {
    /// Posted by the pipeline when a book is finished (object: the book id).
    static let audiobookCompleted = Notification.Name("AudiobookForge.audiobookCompleted")
}
