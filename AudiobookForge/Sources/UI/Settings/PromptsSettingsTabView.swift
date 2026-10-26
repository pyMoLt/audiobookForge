import SwiftUI

/// Prompt templates for summaries and image descriptions. Budgets and
/// chapter limits live in "KI & Zusammenfassung" (no duplicates).
struct PromptsSettingsTabView: View {
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        VStack(alignment: .leading, spacing: 12) {
            promptCard(
                title: "System-Prompt",
                note: "Hörbuch-Regeln (Zahlen als Wörter, keine Quellenverweise …). Das Modell setzt „## Zwischenüberschriften“ an Themenwechseln — daraus entstehen die KI-Kapitel; das Format „## “ bitte beibehalten.",
                text: $store.settings.promptTemplates.systemPrompt, height: 170)
            promptCard(
                title: "Nutzer-Prompt",
                note: "Platzhalter: {{text}}, {{title}}. Ein Aufruf kann mehrere Original-Kapitel gebündelt enthalten.",
                text: $store.settings.promptTemplates.userPromptTemplate, height: 150)
            promptCard(
                title: "Bildbeschreibung · Vorlesen",
                note: "Platzhalter: {{caption}}, {{language}}. Antwort „SKIP“ überspringt das Bild.",
                text: $store.settings.promptTemplates.visionPrompt, height: 130)
            promptCard(
                title: "Bildbeschreibung · Zusammenfassung",
                note: "Kürzere Beschreibung, die der Zusammenfassung an der Bildstelle mitgegeben wird.",
                text: $store.settings.promptTemplates.visionPromptShort, height: 110)
            HStack {
                Spacer()
                Button(role: .destructive) {
                    settingsStore.settings.promptTemplates = PromptTemplates()
                } label: {
                    Label("Vorlagen zurücksetzen", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(FlowButtonStyle(variant: .destructive, size: .small))
            }
        }
    }

    private func promptCard(title: String, note: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title)).flowFont(.body, weight: .semibold)
            Text(L(note)).flowFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: text)
                .appFont(size: 12, design: .monospaced)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: height)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
        .padding(18)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }
}
