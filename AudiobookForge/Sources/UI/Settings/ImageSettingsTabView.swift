import SwiftUI

/// Figures, captions and textbook clean-up — everything that decides what
/// of a figure-heavy book is read aloud and how.
struct ImageSettingsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 30) {
            PillSection("Abbildungen", footer: "Jede Beschreibung wird als eigener Absatz genau an der Stelle des Bildes eingefügt — nie mitten im Satz. Pro Buch in der Prüfung umschaltbar; Beschreibungen werden gespeichert und wiederverwendet.") {
                PillRow(title: "Standard für neue Bücher") {
                    SegmentedPills(selection: $store.settings.describeImagesWithVisionModel, options: [
                        PillOption(value: true, label: "Beschreiben", systemImage: "eye"),
                        PillOption(value: false, label: "Verwerfen", systemImage: "eye.slash"),
                    ])
                }
                PillRow(title: "Beschreibungen verwenden in") {
                    PillPicker(selection: $store.settings.imageDescriptionScope,
                               options: ImageDescriptionScope.allCases.map { PillOption(value: $0, label: $0.displayName) })
                }
                PillRow(title: "Einleitungswort", subtitle: "Leer = automatisch „Abbildung“ / „Figure“.") {
                    TextField("Abbildung", text: $store.settings.imageDescriptionLabel)
                        .textFieldStyle(.flow)
                        .frame(width: 200)
                }
            }

            PillSection("Welche Bilder ans Modell gehen", footer: "Ein Bild muss alle Grenzen erfüllen; Logos, Icons und Zierlinien fallen so heraus. Wiederkehrende Bilder (Wasserzeichen) werden immer verworfen; dekorative Bilder beantwortet das Modell mit „SKIP“.") {
                PillRow(title: "Mindestgröße", subtitle: "Kürzere Bildseite") {
                    PillStepper(value: $store.settings.minimumImageDimensionForVisionPass, range: 0...1000, step: 20, suffix: "px")
                }
                PillRow(title: "Mindestfläche", subtitle: "Anteil an der Seite") {
                    PillSlider(value: $store.settings.minimumImageAreaPercent, range: 0...30, step: 0.5, format: "%.1f %%")
                }
                PillRow(title: "Mindest-Dateigröße") {
                    PillStepper(value: $store.settings.minimumImageKilobytes, range: 0...500, step: 2, suffix: "KB")
                }
                PillRow(title: "Maximales Seitenverhältnis") {
                    PillSlider(value: $store.settings.maximumImageAspectRatio, range: 2...20, step: 0.5, format: "%.1f : 1")
                }
                PillRow(title: "Grafiken, Schemata und Tabellen erkennen", subtitle: "Gezeichnete Abbildungen zählen als Bild.") {
                    PillToggle(isOn: $store.settings.detectVectorFigures)
                }
            }

            PillSection("Vision-Modell", footer: "Braucht ein Modell mit Bildverständnis (z. B. Qwen3.5/3.6 als VLM in oMLX). Mehr parallele Beschreibungen nutzen Continuous Batching.") {
                PillRow(title: "Parallele Bildbeschreibungen", subtitle: "Zusammen mit der Sprachausgabe unter „Leistung“ eingestellt.") {
                    Button(String(format: L("%d · in Leistung ändern"), store.settings.visionParallelRequests)) {
                        NotificationCenter.default.post(name: .openSettingsPane, object: SettingsPane.performance.rawValue)
                    }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                }
                PillRow(title: "Thinking für Bildbeschreibung") {
                    SegmentedPills(selection: $store.settings.llmVisionThinkingMode,
                                   options: LLMThinkingMode.allCases.map { PillOption(value: $0, label: $0.displayName) }, size: .small)
                }
                PillRow(title: "Vision-Modell-ID", subtitle: "Leer = Zusammenfassungsmodell") {
                    TextField("Modell-ID", text: $store.settings.llmVisionModelOverride)
                        .textFieldStyle(.flow)
                        .frame(width: 260)
                }
                PillRow(title: "Timeout pro Bild") {
                    PillSlider(value: $store.settings.llmVisionTimeoutSeconds, range: 10...600, step: 10, format: "%.0f s")
                }
            }

            PillSection("Lehrbücher & Skripte", footer: "Immer aktiv: Silbentrennung wird zusammengeführt, Ligaturen aufgelöst, Kolumnentitel und Seitenzahlen entfernt, Verzeichnisse übersprungen, Tabellen (EPUB) zeilenweise gelesen.") {
                PillRow(title: "Beschriftungen in Abbildungen nicht vorlesen", subtitle: "z. B. „rER“, „N*“, „a b“") {
                    PillToggle(isOn: $store.settings.removeFigureLabelText)
                }
                PillRow(title: "Bildunterschriften vorlesen", subtitle: "„Abb. 6.8 …“") {
                    PillToggle(isOn: $store.settings.keepFigureCaptions)
                }
                PillRow(title: "Reine Verweise weglassen", subtitle: "„(S. 403)“, „(▶ Abb. 6.8)“") {
                    PillToggle(isOn: $store.settings.removeCrossReferences)
                }
            }
        }
    }
}
