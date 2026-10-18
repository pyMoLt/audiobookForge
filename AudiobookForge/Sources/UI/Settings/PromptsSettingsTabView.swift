import SwiftUI

struct PromptsSettingsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var settingsStore = settingsStore
        Form {
            Section("System-Prompt") {
                Text("Der Standard-Prompt enthält Hörbuch-Regeln: Zahlen, Jahreszahlen, Einheiten und Prozent als Zahlwörter, Abkürzungen ausgeschrieben, keine Quellenverweise, Formeln, URLs oder Klammern — alles so, dass es vorgelesen sauber klingt. Frei anpassbar; „Auf Standardwerte zurücksetzen“ holt den aktuellen Standard zurück.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Steuert auch, dass das Modell selbst „## Zwischenüberschriften“ an Themenwechseln einfügt — daraus baut die App die Kapitelstruktur im KI-Modus. Behalte das exakte „## “-Format bei, sonst kann die App die Antwort nicht mehr in Kapitel aufteilen (die ganze Antwort wird dann einfach ein einziges, gröberes Kapitel statt mehrerer — nichts geht verloren, nur die Feingliederung).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settingsStore.settings.promptTemplates.systemPrompt)
                    .frame(minHeight: 160)
                    .font(.system(.body, design: .monospaced))
            }
            Section("Nutzer-Prompt-Vorlage") {
                Text("Platzhalter: {{text}}, {{title}} (Buchtitel). Ein Aufruf kann mehrere Original-Kapitel/Abschnitte gebündelt enthalten (siehe Zeichen-Budget unten) — es gibt daher keinen {{chapter_title}}-Platzhalter mehr für ein einzelnes Kapitel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settingsStore.settings.promptTemplates.userPromptTemplate)
                    .frame(minHeight: 160)
                    .font(.system(.body, design: .monospaced))
            }
            Section("Zeichen-Budget pro Aufruf") {
                Stepper(value: $settingsStore.settings.summarizationChunkCharacterBudget, in: 10000...150000, step: 5000) {
                    Text("~\(settingsStore.settings.summarizationChunkCharacterBudget / 1000)k Zeichen pro Aufruf")
                }
                Text("Gilt für den Dokumenttyp „Allgemein“ — Buch/Paper/Report haben eigene, feiner abgestimmte Budgets (siehe Dokumenttyp-Einstellung). Mehrere kurze Original-Kapitel werden bis zu diesem Budget (±15% Toleranz, um keinen winzigen Rest-Aufruf zu erzeugen) in einem Aufruf gebündelt; ein einzelnes zu langes Kapitel wird stattdessen an Absatzgrenzen aufgeteilt. Kleiner bei schwächeren/kleineren lokalen Modellen oder engerem Kontextfenster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Bildbeschreibung – Vorlesemodus") {
                TextEditor(text: $settingsStore.settings.promptTemplates.visionPrompt)
                    .frame(minHeight: 140)
                    .font(.system(.body, design: .monospaced))
                Text("Für jede Abbildung beim normalen Vorlesen. Platzhalter: {{caption}} (Bildunterschrift/Alternativtext aus dem Buch), {{language}} (Sprache des Buchs). Antwortet das Modell exakt „SKIP“, wird das Bild übersprungen (Logos, Zierelemente). Die Beschreibung wird als „Abbildung: …“ genau an der Stelle des Bildes vorgelesen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Bildbeschreibung – Zusammenfassungsmodus") {
                TextEditor(text: $settingsStore.settings.promptTemplates.visionPromptShort)
                    .frame(minHeight: 110)
                    .font(.system(.body, design: .monospaced))
                Text("Kürzere Beschreibung, die der Zusammenfassung als normaler Absatz an der Bildstelle mitgegeben wird — das Modell entscheidet selbst, ob und wie es sie einbaut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Batch-Toleranz") {
                Stepper(value: $settingsStore.settings.summarizationBatchTolerance, in: 0...0.5, step: 0.05) {
                    Text("±\(Int((settingsStore.settings.summarizationBatchTolerance * 100).rounded())) % um die gleichmäßige Zielgröße")
                }
                Text("Wie weit ein Zusammenfassungs-Aufruf über die gleichmäßig verteilte Zielgröße hinausgehen darf, damit kein winziger Rest-Aufruf entsteht. Gilt nicht für Bücher (dort ein Aufruf pro Kapitel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Maximale KI-Kapitellänge") {
                Stepper(value: $settingsStore.settings.aiChapterMaxCharacters, in: 0...60000, step: 1000) {
                    Text(settingsStore.settings.aiChapterMaxCharacters == 0 ? "Aus" : "~\(settingsStore.settings.aiChapterMaxCharacters / 1000)k Zeichen (≈ \(settingsStore.settings.aiChapterMaxCharacters / 900) min)")
                }
                Text("Absicherung unabhängig vom Modell: Setzt das Modell zu wenige Zwischenüberschriften, wird ein überlanges KI-Kapitel an Absatzgrenzen in „Teil 1/2 …“ gegliedert. 0 = aus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Auf Standardwerte zurücksetzen", role: .destructive) {
                    settingsStore.settings.promptTemplates = PromptTemplates()
                }
            }
        }
        .formStyle(.grouped)
    }
}
