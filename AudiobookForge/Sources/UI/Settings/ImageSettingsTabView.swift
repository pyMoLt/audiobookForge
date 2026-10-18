import SwiftUI

/// Figures, captions and textbook clean-up — everything that decides what
/// of a figure-heavy book is read aloud and how.
struct ImageSettingsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var settingsStore = settingsStore
        Form {
            Section("Abbildungen") {
                Picker("Standard für neue Bücher", selection: $settingsStore.settings.describeImagesWithVisionModel) {
                    Text("Beschreiben (Vision-Modell)").tag(true)
                    Text("Verwerfen").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Beschreibungen verwenden in", selection: $settingsStore.settings.imageDescriptionScope) {
                    ForEach(ImageDescriptionScope.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Einleitungswort (leer = automatisch: „Abbildung“ / „Figure“)", text: $settingsStore.settings.imageDescriptionLabel)
                    .textFieldStyle(.roundedBorder)
                Text("Beim Vorlesen wird jede Beschreibung als eigener Absatz genau an der Stelle des Bildes eingefügt — bei einer Bildunterschrift direkt danach, sonst am nächsten Absatzende, nie mitten im Satz. Im Zusammenfassungsmodus bekommt das Modell eine kürzere Beschreibung als Absatz an der Bildstelle und entscheidet selbst, ob es sie verwendet. Pro Buch im Prüfbildschirm umschaltbar. Beschreibungen werden gespeichert und bei einem erneuten Lauf wiederverwendet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Welche Bilder ans Modell gehen") {
                Stepper(value: $settingsStore.settings.minimumImageDimensionForVisionPass, in: 0...1000, step: 20) {
                    Text("Mindestgröße: \(settingsStore.settings.minimumImageDimensionForVisionPass) px (kürzere Seite)")
                }
                Stepper(value: $settingsStore.settings.minimumImageAreaPercent, in: 0...30, step: 0.5) {
                    Text("Mindestfläche: \(settingsStore.settings.minimumImageAreaPercent, specifier: "%.1f") % der Seite")
                }
                Stepper(value: $settingsStore.settings.minimumImageKilobytes, in: 0...500, step: 2) {
                    Text("Mindest-Dateigröße: \(settingsStore.settings.minimumImageKilobytes) KB")
                }
                Stepper(value: $settingsStore.settings.maximumImageAspectRatio, in: 2...20, step: 0.5) {
                    Text("Maximales Seitenverhältnis: \(settingsStore.settings.maximumImageAspectRatio, specifier: "%.1f") : 1")
                }
                Toggle("Gezeichnete Grafiken, Schemata und Tabellen als Abbildung erkennen", isOn: $settingsStore.settings.detectVectorFigures)
                Text("Ein Bild muss alle Grenzen erfüllen; Logos, Icons, Pfeile, Aufzählungszeichen und Zierlinien fallen so heraus. Bilder an derselben Stelle auf vielen Seiten (Logos, Wasserzeichen) werden immer verworfen. Zusätzlich antwortet das Modell bei rein dekorativen Bildern mit „SKIP“.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Vision-Modell") {
                Stepper("Parallele Bildbeschreibungen: \(settingsStore.settings.visionParallelRequests)", value: $settingsStore.settings.visionParallelRequests, in: 1...8)
                Picker("Thinking für Bildbeschreibung", selection: $settingsStore.settings.llmVisionThinkingMode) {
                    ForEach(LLMThinkingMode.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Vision-Modell-ID (leer = Zusammenfassungsmodell)", text: $settingsStore.settings.llmVisionModelOverride)
                    .textFieldStyle(.roundedBorder)
                Stepper("Timeout pro Bild: \(Int(settingsStore.settings.llmVisionTimeoutSeconds)) s", value: $settingsStore.settings.llmVisionTimeoutSeconds, in: 10...600, step: 10)
                Text("Braucht ein Modell mit Bildverständnis (z. B. Qwen3.5/3.6 als VLM in oMLX). 1 = Bilder strikt nacheinander; mehr = oMLX verarbeitet mehrere gleichzeitig (Continuous Batching).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Lehrbücher & Skripte: Text-Bereinigung") {
                Toggle("Beschriftungen in Abbildungen nicht vorlesen (z. B. „rER“, „N*“, „a b“)", isOn: $settingsStore.settings.removeFigureLabelText)
                Toggle("Bildunterschriften vorlesen („Abb. 6.8 …“)", isOn: $settingsStore.settings.keepFigureCaptions)
                Toggle("Reine Verweise weglassen („(S. 403)“, „(▶ Abb. 6.8)“)", isOn: $settingsStore.settings.removeCrossReferences)
                Text("Immer aktiv: Silbentrennung am Zeilenende wird zusammengeführt, Ligaturen aufgelöst, Kolumnentitel, Seitenzahlen und Randmarken entfernt, Inhalts- und Stichwortverzeichnisse übersprungen, Tabellen (EPUB) zeilenweise als Sätze gelesen. Beschriftungen und Bildunterschriften wirken beim nächsten Import; Verweise und Abbildungsmodus beim nächsten Verarbeitungslauf.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
