import SwiftUI

struct ReviewView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PipelineController.self) private var pipelineController
    @StateObject private var voicePreview = VoicePreviewPlayer()
    let bookID: UUID

    @State private var showSplitEditor = false
    @State private var splitEditorTargetChapterID: UUID? = nil

    private var book: BookProject {
        libraryStore.book(id: bookID) ?? BookProject(title: "", author: "", sourceType: .pdf, sourceURL: URL(fileURLWithPath: "/"), chapters: [], outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1.0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = book.lastErrorMessage {
                    errorBanner(error)
                }

                metadataSection
                modeSection
                granularitySection
                outputSection
                chapterSection
            }
            .padding(24)
        }
        .navigationTitle(book.title.isEmpty ? "Neues Buch" : book.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pipelineController.enqueue(bookID: bookID)
                } label: {
                    Label(pipelineController.isAnyBookActive ? "Zur Warteschlange hinzufügen" : "Verarbeitung starten", systemImage: pipelineController.isAnyBookActive ? "text.badge.plus" : "play.fill")
                }
                .disabled(book.chapters.isEmpty)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if book.mode == .summary {
                Button("Stattdessen im Transkriptions-Modus fortfahren") {
                    pipelineController.fallBackToTranscription(bookID: bookID)
                }
            }
        }
        .padding(12)
        .glassPanel()
    }

    private var describeImagesValue: Bool {
        book.describeImages ?? settingsStore.settings.describeImagesWithVisionModel
    }

    private func bindingForDescribeImages() -> Binding<Bool> {
        Binding(
            get: { describeImagesValue },
            set: { newValue in
                var updated = book
                updated.describeImages = newValue
                libraryStore.upsert(updated)
            }
        )
    }

    private var detectedImagesCount: Int {
        if let count = book.detectedImageCount, count > 0 {
            return count
        }
        return (book.chapters + (book.sourceChapters ?? [])).reduce(into: Set<String>()) { keys, chapter in
            ImageDescriptionMarker.figures(in: chapter.cleanedText).forEach { keys.insert($0.ref.key) }
        }.count
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadaten").font(.headline)
            LabeledContent("Titel") {
                TextField("Titel", text: bindingForTitle())
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Autor") {
                TextField("Autor (optional)", text: bindingForAuthor())
                    .textFieldStyle(.roundedBorder)
            }

            Divider()
            let imgCount = detectedImagesCount
            HStack(spacing: 8) {
                Image(systemName: imgCount > 0 ? "photo.badge.checkmark" : "photo")
                    .foregroundStyle(imgCount > 0 ? .purple : .secondary)
                if imgCount > 0 {
                    Text("\(imgCount) Abbildung\(imgCount == 1 ? "" : "en") erkannt")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.purple)
                    Spacer()
                    Picker("Abbildungen", selection: bindingForDescribeImages()) {
                        Text("Beschreiben").tag(true)
                        Text("Verwerfen").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                } else {
                    Text("Keine Abbildungen erkannt (oder alle unter den Größenfiltern)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if imgCount > 0 {
                Text(describeImagesValue
                     ? "Das Vision-Modell beschreibt jede Abbildung; die Beschreibung wird als „Abbildung: …“ genau an ihrer Stelle vorgelesen (im KI-Modus als kurze Zusatzinfo für die Zusammenfassung)."
                     : "Abbildungen werden übersprungen — nur der Text wird vorgelesen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassPanel()
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verarbeitungsmodus").font(.headline)
            Picker("Modus", selection: bindingForMode()) {
                ForEach(ProcessingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if book.mode == .summary {
                Text("Kapitel werden möglichst detailgetreu verdichtet (Redundanz und stilistische Ausschmückung entfernt, Fakten und Zahlen bleiben erhalten) — kein separater Detailgrad-Regler, das hat sich in Tests als zuverlässiger erwiesen als Prozent- oder Stufenvorgaben.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Dokumenttyp", selection: bindingForDocumentType()) {
                    ForEach(DocumentType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                Text(book.documentType.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Picker("Sprache des Buchs", selection: bindingForBookLanguage()) {
                    ForEach(languageChoices(including: book.languageCode), id: \.self) { code in
                        Text(LanguageDetector.displayName(code) + (code == book.detectedLanguageCode && book.languageOverride == nil ? " (erkannt)" : "")).tag(code)
                    }
                }
                if book.mode == .summary {
                    Picker("Sprache der Zusammenfassung", selection: bindingForSummaryLanguage()) {
                        Text("Wie Original").tag(String?.none)
                        ForEach(LanguageDetector.selectableLanguages, id: \.self) { code in
                            Text(LanguageDetector.displayName(code)).tag(String?.some(code))
                        }
                    }
                }
            }
            Text(book.mode == .summary
                 ? "Vorgelesen wird in der Sprache der Zusammenfassung; Bildbeschreibungen folgen ihr. Stimme passend wählen."
                 : "Vorgelesen wird der Originaltext; Bildbeschreibungen werden in der Sprache des Buchs geschrieben. Wird beim Start neu erkannt, solange du sie nicht selbst festlegst.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Engine", selection: bindingForEngine()) {
                    ForEach(TTSEngineID.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Picker("Stimme", selection: bindingForVoice()) {
                    ForEach(TTSEngineFactory.availableVoices(for: book.engineID)) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
            }
            HStack {
                Text("Geschwindigkeit: \(book.speechSpeed, specifier: "%.2f")×")
                Slider(value: bindingForSpeed(), in: 0.5...2.0, step: 0.05)
                    .frame(width: 220)
                Spacer()
                previewButton
            }
            if let previewError = voicePreview.errorMessage {
                Text(previewError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .glassPanel()
    }

    @ViewBuilder
    private var previewButton: some View {
        Button {
            if voicePreview.isPlaying || voicePreview.isGenerating {
                voicePreview.stop()
            } else if let sampleText = book.sortedChapters.first?.textForNarration {
                voicePreview.preview(text: sampleText, engineID: book.engineID, voice: book.voice, speed: book.speechSpeed, settings: settingsStore.settings)
            }
        } label: {
            if voicePreview.isGenerating {
                Label("Erzeuge Vorschau …", systemImage: "waveform")
            } else if voicePreview.isPlaying {
                Label("Stopp", systemImage: "stop.fill")
            } else {
                Label("Stimme testen", systemImage: "play.circle")
            }
        }
        .disabled(book.chapters.isEmpty)
    }

    private var granularitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if book.mode == .transcription {
                transcriptionGranularityContent
            } else {
                summaryGranularityContent
            }
        }
        .padding(16)
        .glassPanel()
    }

    private var transcriptionGranularityContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kapiteleinteilung & Track-Größe").font(.headline)
                Spacer()
                if book.targetChapterCharacters != nil && book.targetChapterCharacters != 0 {
                    Button("Original-Gliederung") {
                        updateTargetChapterCharacters(0)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
            }

            Text("Bestimmt, wie viele Abschnitte zu einem gemeinsamen Hörbuch-Track gebündelt werden. Verändern passt die Kapitelstruktur sofort live an.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Slider(
                    value: bindingForTargetChapterCharacters(),
                    in: 2000...40000,
                    step: 1000
                )
                Text(effectiveTargetChapterCharacters == 0 ? "Original" : "\(formatNumber(effectiveTargetChapterCharacters)) Zeichen")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(width: 130, alignment: .trailing)
            }

            HStack(spacing: 12) {
                statCard(
                    title: "Kapitel",
                    value: "\(book.chapters.count)",
                    detail: book.rawImportedChapters.map { "\($0.count) im Original" } ?? ""
                )
                statCard(
                    title: "Durchschnitt",
                    value: "\(formatNumber(averageChapterCharacters)) Zeichen",
                    detail: "ca. \(formatNumber(averageChapterCharacters / 5)) Wörter"
                )
                statCard(
                    title: "Dauer pro Track",
                    value: formatDuration(minutes: estimatedMinutesPerChapter),
                    detail: "bei normalem Tempo"
                )
                statCard(
                    title: "Gesamtdauer",
                    value: formatDuration(minutes: estimatedTotalMinutes),
                    detail: String(format: "%.2f× Tempo", book.speechSpeed)
                )
            }
        }
    }

    private var summaryGranularityContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("KI-Kontextgröße & Portionierung").font(.headline)
                Spacer()
                if book.summarizationBudget != nil {
                    Button("Standard (\(formatNumber(settingsStore.settings.summarizationChunkCharacterBudget(for: book.documentType))))") {
                        updateSummarizationBudget(nil)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
            }

            Text("Bestimmt, wie viel Text das Sprachmodell (LLM) pro Aufruf auf einmal liest. Kleinere Portionen (15k–25k) verhindern Vergessen und wahren Details; größere Portionen (35k–60k) erfassen größere Zusammenhänge schneller.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Slider(
                    value: bindingForSummarizationBudget(),
                    in: 8000...70000,
                    step: 2000
                )
                Text("\(formatNumber(effectiveSummarizationBudget)) Zeichen")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .frame(width: 130, alignment: .trailing)
            }

            HStack(spacing: 12) {
                statCard(
                    title: "LLM-Aufrufe",
                    value: "\(plannedLLMCalls)",
                    detail: "\(settingsStore.settings.activeParallelRequests) parallel"
                )
                statCard(
                    title: "Kontext pro Call",
                    value: "\(formatNumber(averageContextCharacters)) Zeichen",
                    detail: "~ \(formatNumber(averageContextTokens)) Tokens"
                )
                statCard(
                    title: "Geschätzte Dauer",
                    value: formatLLMDuration(calls: plannedLLMCalls),
                    detail: "\(settingsStore.settings.llmProvider.displayName)"
                )
                statCard(
                    title: "Eingangstext",
                    value: "\(formatNumber(totalCharacters)) Zeichen",
                    detail: "\(book.chapters.count) Abschnitte"
                )
            }

            DisclosureGroup("Eingangs-Gliederung anpassen (\(book.chapters.count) Abschnitte)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Slider(
                            value: bindingForTargetChapterCharacters(),
                            in: 2000...40000,
                            step: 1000
                        )
                        Text(effectiveTargetChapterCharacters == 0 ? "Original" : "\(formatNumber(effectiveTargetChapterCharacters)) Zeichen")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width: 110, alignment: .trailing)
                    }
                    Text("Gliedert die Abschnitte vor dem Senden an das Modell grober oder feiner vor.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    private func statCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var effectiveTargetChapterCharacters: Int {
        book.targetChapterCharacters ?? settingsStore.settings.targetChapterCharacters
    }

    private func bindingForTargetChapterCharacters() -> Binding<Double> {
        Binding(
            get: { Double(effectiveTargetChapterCharacters == 0 ? 2000 : effectiveTargetChapterCharacters) },
            set: { newValue in
                let target = Int(newValue)
                updateTargetChapterCharacters(target)
            }
        )
    }

    private func updateTargetChapterCharacters(_ newTarget: Int) {
        update { book in
            book.targetChapterCharacters = newTarget
            let raw = book.rawImportedChapters ?? book.chapters
            if book.rawImportedChapters == nil {
                book.rawImportedChapters = raw
            }
            if newTarget <= 0 {
                book.chapters = raw
            } else {
                book.chapters = ChapterRebundler.rebundle(chapters: raw, targetCharacters: newTarget)
            }
        }
    }

    private var effectiveSummarizationBudget: Int {
        book.summarizationBudget ?? settingsStore.settings.summarizationChunkCharacterBudget(for: book.documentType)
    }

    private func bindingForSummarizationBudget() -> Binding<Double> {
        Binding(
            get: { Double(effectiveSummarizationBudget) },
            set: { newValue in
                let budget = Int(newValue)
                updateSummarizationBudget(budget)
            }
        )
    }

    private func updateSummarizationBudget(_ newBudget: Int?) {
        update { book in
            book.summarizationBudget = newBudget
        }
    }

    private var totalCharacters: Int {
        book.chapters.reduce(0) { $0 + $1.cleanedText.count }
    }

    private var averageChapterCharacters: Int {
        book.chapters.isEmpty ? 0 : totalCharacters / book.chapters.count
    }

    private var estimatedMinutesPerChapter: Double {
        Double(averageChapterCharacters) / 950.0 / max(0.1, book.speechSpeed)
    }

    private var estimatedTotalMinutes: Double {
        Double(totalCharacters) / 950.0 / max(0.1, book.speechSpeed)
    }

    private var plannedLLMCalls: Int {
        let chapters = book.sourceChapters ?? book.chapters
        let budget = effectiveSummarizationBudget
        let batches = SummarizerClient.buildBatches(
            chapters: chapters.map { ($0.title, $0.cleanedText) },
            documentType: book.documentType,
            budget: budget,
            tolerance: settingsStore.settings.summarizationBatchTolerance
        )
        var totalCalls = 0
        for indices in batches {
            let combinedLength = indices.map { chapters[$0].cleanedText.count }.reduce(0, +)
            let pieces = max(1, Int(ceil(Double(combinedLength) / Double(budget))))
            totalCalls += pieces
        }
        return max(1, totalCalls)
    }

    private var averageContextCharacters: Int {
        let total = totalCharacters
        let calls = plannedLLMCalls
        return calls > 0 ? total / calls : 0
    }

    private var averageContextTokens: Int {
        Int(Double(averageContextCharacters) / 4.2)
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatDuration(minutes: Double) -> String {
        let totalMins = Int(minutes.rounded())
        let hours = totalMins / 60
        let mins = totalMins % 60
        if hours > 0 {
            return "\(hours) Std. \(mins) Min."
        } else {
            return "\(mins) Min."
        }
    }

    private func formatLLMDuration(calls: Int) -> String {
        let parallel = max(1, settingsStore.settings.activeParallelRequests)
        let totalSeconds = (Double(calls) * 16.0) / Double(parallel)
        let totalMins = Int(ceil(totalSeconds / 60.0))
        if totalMins <= 1 {
            return "< 1 Min."
        } else {
            return "ca. \(totalMins) Min."
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ausgabe").font(.headline)
            Picker("Format", selection: bindingForFormat()) {
                ForEach(OutputFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            Text("Zielordner: \(settingsStore.settings.outputBaseFolderPath)/\(settingsStore.settings.outputFolderTemplate.relativePath(title: book.title, author: book.author))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassPanel()
    }

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kapitel (\(book.chapters.count))").font(.headline)
                Button {
                    splitEditorTargetChapterID = nil
                    showSplitEditor = true
                } label: {
                    Image(systemName: "book.pages")
                }
                .help("Kapitelstruktur bearbeiten")
                Spacer()
                Text("Zum Umsortieren ziehen").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(book.sortedChapters.enumerated()), id: \.element.id) { index, chapter in
                    ChapterRow(
                        chapter: chapter,
                        index: index,
                        onRename: { newTitle in renameChapter(id: chapter.id, title: newTitle) },
                        onMergeWithPrevious: index > 0 ? { mergeWithPrevious(chapterID: chapter.id) } : nil,
                        onDelete: book.chapters.count > 1 ? { deleteChapter(id: chapter.id) } : nil,
                        onSplit: {
                            splitEditorTargetChapterID = chapter.id
                            showSplitEditor = true
                        }
                    )
                    .draggable(chapter.id.uuidString)
                    .dropDestination(for: String.self) { droppedIDs, _ in
                        guard let draggedIDString = droppedIDs.first, let draggedID = UUID(uuidString: draggedIDString) else { return false }
                        moveChapter(draggedID: draggedID, toIndex: index)
                        return true
                    }
                    if index < book.chapters.count - 1 {
                        Divider()
                    }
                }
            }
            .glassPanel()
            .sheet(isPresented: $showSplitEditor) {
                ChapterSplitEditorView(bookID: bookID, targetChapterID: splitEditorTargetChapterID)
            }
        }
    }

    private func moveChapter(draggedID: UUID, toIndex targetIndex: Int) {
        update { book in
            var sorted = book.sortedChapters
            guard let sourceIndex = sorted.firstIndex(where: { $0.id == draggedID }), sourceIndex != targetIndex else { return }
            let moved = sorted.remove(at: sourceIndex)
            sorted.insert(moved, at: min(max(targetIndex, 0), sorted.count))
            for (newOrder, chapter) in sorted.enumerated() {
                if let realIndex = book.chapters.firstIndex(where: { $0.id == chapter.id }) {
                    book.chapters[realIndex].order = newOrder
                }
            }
        }
    }

    // MARK: - Bindings

    private func update(_ mutate: (inout BookProject) -> Void) {
        var updated = book
        mutate(&updated)
        if updated.status == .needsReview, updated.mode == .transcription, updated.sourceChapters != nil {
            updated.sourceChapters = updated.chapters
        }
        libraryStore.upsert(updated)
    }

    private func bindingForTitle() -> Binding<String> {
        Binding(get: { book.title }, set: { newValue in update { $0.title = newValue } })
    }

    private func bindingForAuthor() -> Binding<String> {
        Binding(get: { book.author }, set: { newValue in update { $0.author = newValue } })
    }

    private func bindingForMode() -> Binding<ProcessingMode> {
        Binding(get: { book.mode }, set: { newValue in update { $0.mode = newValue } })
    }

    private func languageChoices(including code: String) -> [String] {
        LanguageDetector.selectableLanguages.contains(code) ? LanguageDetector.selectableLanguages : [code] + LanguageDetector.selectableLanguages
    }

    private func bindingForBookLanguage() -> Binding<String> {
        Binding(get: { book.languageCode }, set: { newValue in update { $0.languageOverride = newValue } })
    }

    private func bindingForSummaryLanguage() -> Binding<String?> {
        Binding(get: { book.summaryLanguageCode }, set: { newValue in update { $0.summaryLanguageCode = newValue } })
    }

    private func bindingForDocumentType() -> Binding<DocumentType> {
        Binding(get: { book.documentType }, set: { newValue in update { $0.documentType = newValue } })
    }


    private func bindingForVoice() -> Binding<String> {
        Binding(get: { book.voice }, set: { newValue in update { $0.voice = newValue } })
    }

    private func bindingForEngine() -> Binding<TTSEngineID> {
        Binding(
            get: { book.engineID },
            set: { newEngine in
                update {
                    $0.engineID = newEngine
                    $0.voice = settingsStore.settings.defaultVoice(for: newEngine)
                    $0.speechSpeed = settingsStore.settings.defaultSpeed(for: newEngine)
                }
            }
        )
    }

    private func bindingForSpeed() -> Binding<Double> {
        Binding(get: { book.speechSpeed }, set: { newValue in update { $0.speechSpeed = newValue } })
    }

    private func bindingForFormat() -> Binding<OutputFormat> {
        Binding(get: { book.outputFormat }, set: { newValue in update { $0.outputFormat = newValue } })
    }

    private func renameChapter(id: UUID, title: String) {
        update { book in
            if let index = book.chapters.firstIndex(where: { $0.id == id }) {
                book.chapters[index].title = title
            }
        }
    }

    private func mergeWithPrevious(chapterID: UUID) {
        update { book in
            let sorted = book.sortedChapters
            guard let currentIndex = sorted.firstIndex(where: { $0.id == chapterID }), currentIndex > 0 else { return }
            let previous = sorted[currentIndex - 1]
            let current = sorted[currentIndex]
            guard let prevRealIndex = book.chapters.firstIndex(where: { $0.id == previous.id }) else { return }
            book.chapters[prevRealIndex].rawText += "\n\n" + current.rawText
            book.chapters[prevRealIndex].cleanedText += "\n\n" + current.cleanedText
            book.chapters.removeAll { $0.id == current.id }
            renumberChapters(&book)
        }
    }

    private func deleteChapter(id: UUID) {
        update { book in
            let sorted = book.sortedChapters
            guard let currentIndex = sorted.firstIndex(where: { $0.id == id }) else { return }
            let current = sorted[currentIndex]

            // Merge text into the previous chapter (or the next one if
            // this is the very first) — nothing gets lost.
            if currentIndex > 0 {
                let previous = sorted[currentIndex - 1]
                if let prevIdx = book.chapters.firstIndex(where: { $0.id == previous.id }) {
                    book.chapters[prevIdx].rawText += "\n\n" + current.rawText
                    book.chapters[prevIdx].cleanedText += "\n\n" + current.cleanedText
                }
            } else if sorted.count > 1 {
                let next = sorted[currentIndex + 1]
                if let nextIdx = book.chapters.firstIndex(where: { $0.id == next.id }) {
                    book.chapters[nextIdx].rawText = current.rawText + "\n\n" + book.chapters[nextIdx].rawText
                    book.chapters[nextIdx].cleanedText = current.cleanedText + "\n\n" + book.chapters[nextIdx].cleanedText
                }
            }

            book.chapters.removeAll { $0.id == id }
            renumberChapters(&book)
        }
    }

    private func renumberChapters(_ book: inout BookProject) {
        let sorted = book.sortedChapters
        for (index, chapter) in sorted.enumerated() {
            if let realIndex = book.chapters.firstIndex(where: { $0.id == chapter.id }) {
                book.chapters[realIndex].order = index
            }
        }
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let index: Int
    var onRename: (String) -> Void
    var onMergeWithPrevious: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSplit: (() -> Void)?

    @State private var title: String = ""

    var body: some View {
        HStack {
            Text("\(index + 1).")
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            TextField("Kapiteltitel", text: $title)
                .textFieldStyle(.plain)
                .onAppear { title = chapter.title }
                .onChange(of: title) { _, newValue in onRename(newValue) }
            Spacer()
            Text("\(chapter.cleanedText.count) Zeichen")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                if let onSplit {
                    Button("Kapitel teilen …", action: onSplit)
                }
                if let onMergeWithPrevious {
                    Button("Mit vorherigem zusammenführen", action: onMergeWithPrevious)
                }
                if let onDelete {
                    Button("Löschen", role: .destructive, action: onDelete)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
