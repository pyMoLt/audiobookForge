import SwiftUI

/// Something to read while the workshop runs (v4.3): short nods to games,
/// films and books, plus narrator in-jokes. Shown under the progress, one
/// at a time; switched off under Settings → Appearance → Fun.
enum LoadingQuips {
    static let german: [String] = [
        "Splines werden retikuliert …",
        "Keine Panik. Das Handtuch liegt bereit.",
        "Der Kuchen ist garantiert keine Lüge.",
        "Es ist gefährlich, allein zu gehen. Nimm diese Kopfhörer.",
        "Ein wildes Kapitel erscheint!",
        "Die Prinzessin ist in einem anderen Kapitel.",
        "Du bist erfüllt von Entschlossenheit.",
        "Kapitel werden aus dem Denkarium geholt …",
        "Diese sind nicht die Kapitel, die du suchst. Doch, sind sie.",
        "Ein Kapitel, sie alle zu vertonen …",
        "Folge dem weißen Hasen. Er liest gerade Kapitel 3.",
        "Bitte nicht den Computer ausschalten. Gilt auch für Eulen.",
        "Speichern … Bitte nicht die Konsole ausschalten.",
        "Achtung, der Erzähler trinkt kurz einen Tee.",
        "Kommas werden gezählt. Es sind sehr viele.",
        "Pausen werden kunstvoll platziert …",
        "Vokale werden poliert.",
        "Umlaute werden liebevoll mit Pünktchen versehen.",
        "Fußnoten werden höflich gebeten, leise zu sein.",
        "Der Erzähler übt den dramatischen Blick in die Ferne.",
        "Satzzeichen werden nach Wichtigkeit sortiert.",
        "Ein Semikolon wurde gesichtet. Bleib ruhig.",
        "Kapitel werden in mundgerechte Stücke geschnitten.",
        "Dein Hörbuch wird gerade liebevoll handgeknetet.",
        "Die Bibliothekarin sagt: Psst.",
        "Bücherwürmer werden gefüttert.",
        "Der Hund will wissen, wie lang dieser Hals noch wird.",
        "Die Eule macht sich schon mal warm.",
        "Hustenbonbons für die Stimme werden ausgepackt.",
        "Die Lautstärke wird auf exakt angenehm gestellt.",
        "Leere Seiten werden übersprungen. Sie hatten wenig zu sagen.",
        "Der Erzähler zählt bis drei und atmet ein.",
        "Lade Level 2 … Kapitel, meine ich.",
        "Combo! Fünf Kapitel am Stück.",
        "Achievement in Reichweite. Weiter so.",
        "Die Neural Engine macht Liegestütze.",
        "Bits werden ordentlich gestapelt.",
        "Tetris-Blöcke werden zu Absätzen gestapelt.",
        "Ein Feuer im Kamin wird für die Atmosphäre angezündet.",
        "Kaffee nachgefüllt. Für dich, nicht für die CPU.",
        "Das Orakel sagt: Bald fertig.",
        "Wahrscheinlichkeit, dass es klappt: sehr hoch. Ungefähr 42.",
        "Der Drache bewacht noch Kapitel 7. Wird verhandelt.",
        "Schnell wie ein blauer Igel — zumindest im Kopf.",
        "Fast da. Nur noch ein paar Zwischengegner.",
    ]

    static let english: [String] = [
        "Reticulating splines …",
        "Don't panic. Your towel is ready.",
        "The cake is definitely not a lie.",
        "It's dangerous to go alone. Take these headphones.",
        "A wild chapter appears!",
        "The princess is in another chapter.",
        "You are filled with determination.",
        "Fetching chapters from the pensieve …",
        "These aren't the chapters you're looking for. Actually, they are.",
        "One chapter to narrate them all …",
        "Follow the white rabbit. It's reading chapter 3.",
        "Please don't turn off your computer. That goes for owls, too.",
        "Saving … do not turn off the console.",
        "Heads up: the narrator is having a quick cup of tea.",
        "Counting commas. There are a lot.",
        "Placing pauses with artistic care …",
        "Polishing vowels.",
        "Asking footnotes politely to keep it down.",
        "The narrator is practising a dramatic gaze into the distance.",
        "Sorting punctuation by importance.",
        "A semicolon has been spotted. Stay calm.",
        "Cutting chapters into bite-sized pieces.",
        "Your audiobook is being lovingly hand-kneaded.",
        "The librarian says: shh.",
        "Feeding the bookworms.",
        "The dog wants to know how long this neck will get.",
        "The owl is warming up.",
        "Unwrapping throat sweets for the voice.",
        "Setting the volume to exactly pleasant.",
        "Skipping blank pages. They had little to say.",
        "The narrator counts to three and breathes in.",
        "Loading level 2 … chapter, I mean.",
        "Combo! Five chapters in a row.",
        "Achievement within reach. Keep going.",
        "The Neural Engine is doing push-ups.",
        "Stacking bits neatly.",
        "Stacking Tetris blocks into paragraphs.",
        "Lighting a fire for atmosphere.",
        "Coffee refilled. For you, not for the CPU.",
        "The oracle says: almost done.",
        "Chance of success: very high. Roughly 42.",
        "The dragon still guards chapter 7. Negotiating.",
        "Fast as a blue hedgehog — in spirit, at least.",
        "Almost there. Just a few mini-bosses left.",
    ]

    /// The list for the app's current language (German, else English).
    static var current: [String] {
        (Bundle.main.preferredLocalizations.first ?? "de").hasPrefix("de") ? german : english
    }
}

/// One rotating line under the progress (every 7 s, random order).
struct LoadingQuipLine: View {
    @State private var quip = LoadingQuips.current.randomElement() ?? ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.tertiary)
            Text(verbatim: quip)
                .flowFont(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .id(quip)
                .transition(.opacity)
        }
        .padding(.horizontal, 4)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                let pool = LoadingQuips.current.filter { $0 != quip }
                withAnimation(.easeInOut(duration: 0.4)) { quip = pool.randomElement() ?? quip }
            }
        }
    }
}
