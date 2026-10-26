import SwiftUI

struct ReviewView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PipelineController.self) private var pipelineController
    @StateObject private var voicePreview = VoicePreviewPlayer()
    let bookID: UUID

    @State private var showSplitEditor = false
    /// Expanded outline groups; nil = default (long outlines start collapsed).
    @State private var expandedGroups: Set<String>?
    @State private var showVoiceGallery = false
    @State private var splitEditorTargetChapterID: UUID? = nil
    @State private var preparationReport: PreparationReport?
    @State private var detectedImagesCountCached: Int?

    private var book: BookProject {
        libraryStore.book(id: bookID) ?? BookProject(title: "", author: "", sourceType: .pdf, sourceURL: URL(fileURLWithPath: "/"), chapters: [], outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1.0)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                manuscriptHeader
                if let error = book.lastErrorMessage {
                    errorBanner(error)
                }
                readingSection
                granularitySection
                if detectedImagesCount > 0 { imagesSection }
                outputSection
                preparationSection
                chapterSection.id("chapters")
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollIndicators(.never)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            if info["reviewExpand"] == "first" { expandedGroups = Set(ChapterOutlineGroup.make(book.sortedChapters).prefix(1).map(\.id)) }
            if let target = info["reviewScroll"] { proxy.scrollTo(target, anchor: .top) }
        }
        #endif
        }
        .task(id: book.chapters.count) {
            let chapters = book.chapters
            let settings = settingsStore.settings
            let report = await Task.detached(priority: .utility) {
                PreparationReport.build(chapters: chapters, settings: settings)
            }.value
            self.preparationReport = report
        }
        .task(id: book.id) {
            if book.detectedImageCount == nil {
                let chapters = book.chapters + (book.sourceChapters ?? [])
                let count = await Task.detached(priority: .utility) {
                    chapters.reduce(into: Set<String>()) { keys, chapter in
                        ImageDescriptionMarker.figures(in: chapter.cleanedText).forEach { keys.insert($0.ref.key) }
                    }.count
                }.value
                self.detectedImagesCountCached = count
            }
        }
        .navigationTitle(book.title.isEmpty ? "Neues Buch" : book.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pipelineController.enqueue(bookID: bookID)
                } label: {
                    Label(startLabel, systemImage: pipelineController.isAnyBookActive ? "text.badge.plus" : "waveform.badge.plus")
                }
                .disabled(book.chapters.isEmpty)
            }
        }
    }

    private var startLabel: String {
        L(pipelineController.isAnyBookActive ? "Zur Warteschlange" : "Hörbuch erstellen")
    }

    /// The manuscript on the desk: cover, editable title/author, facts and
    /// the one big action.
    private var manuscriptHeader: some View {
        HStack(alignment: .top, spacing: 24) {
            BookCoverView(book: book, width: 132)
                .rotation3DEffect(.degrees(-8), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.6)
            VStack(alignment: .leading, spacing: 8) {
                Text("Manuskript · bereit zur Prüfung")
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                    .tracking(1.1)
                TextField("Titel", text: bindingForTitle(), axis: .vertical)
                    .textFieldStyle(.plain)
                    .appFont(size: 28, weight: .semibold, design: .serif)
                    .lineLimit(1...3)
                TextField("Autor (optional)", text: bindingForAuthor())
                    .textFieldStyle(.plain)
                    .flowFont(.title3, weight: .regular)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    StatusBadge(text: String(localized: "\(book.chapters.count) Kapitel"), systemImage: "list.bullet", tint: .secondary)
                    StatusBadge(text: "≈ " + formatDuration(minutes: estimatedTotalMinutes), systemImage: "clock", tint: .secondary)
                    StatusBadge(text: LanguageDetector.displayName(book.languageCode), systemImage: "globe", tint: .secondary)
                    StatusBadge(text: book.sourceType == .pdf ? "PDF" : "EPUB", systemImage: "doc", tint: .secondary)
                }
                .padding(.top, 2)
                HStack(spacing: 10) {
                    Button {
                        pipelineController.enqueue(bookID: bookID)
                    } label: {
                        Label(startLabel, systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(FlowButtonStyle(variant: .prominent, size: .large))
                    .disabled(book.chapters.isEmpty)
                    previewButton
                }
                .padding(.top, 8)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).flowFont(.body)
                if book.mode == .summary {
                    Button("Stattdessen im Transkriptions-Modus fortfahren") {
                        pipelineController.fallBackToTranscription(bookID: bookID)
                    }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
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
        if let cached = detectedImagesCountCached {
            return cached
        }
        return 0
    }

    private var imagesSection: some View {
        PillSection("Abbildungen", footer: describeImagesValue
                    ? "Das Vision-Modell beschreibt jede Abbildung; die Beschreibung wird als „Abbildung: …“ genau an ihrer Stelle vorgelesen."
                    : "Abbildungen werden übersprungen — nur der Text wird vorgelesen.") {
            PillRow(title: "\(detectedImagesCount) Abbildung\(detectedImagesCount == 1 ? "" : "en") erkannt", systemImage: "photo.on.rectangle") {
                SegmentedPills(selection: bindingForDescribeImages(), options: [
                    PillOption(value: true, label: "Beschreiben"),
                    PillOption(value: false, label: "Verwerfen"),
                ])
            }
        }
    }

    private var readingSection: some View {
        PillSection("Vorlesen") {
            PillRow(title: "Modus", subtitle: book.mode == .summary
                    ? "Kapitel werden detailgetreu verdichtet — Fakten und Zahlen bleiben."
                    : "Der Originaltext wird vollständig vorgelesen.") {
                SegmentedPills(selection: bindingForMode(), options: ProcessingMode.allCases.map {
                    PillOption(value: $0, label: $0.displayName, systemImage: $0 == .summary ? "text.redaction" : "text.alignleft")
                })
            }
            if book.mode == .summary {
                PillRow(title: "Dokumenttyp", subtitle: book.documentType.explanation) {
                    SegmentedPills(selection: bindingForDocumentType(), options: DocumentType.allCases.map {
                        PillOption(value: $0, label: $0.displayName, systemImage: $0.systemImage)
                    })
                }
            }
            voiceCard
            PillRow(title: "Tempo", subtitle: "Sprechgeschwindigkeit dieses Buchs.") {
                PillSlider(value: bindingForSpeed(), range: 0.5...2.0, step: 0.05, format: "%.2f×")
            }
            PillRow(title: "Sprache des Buchs", subtitle: book.languageOverride == nil && book.detectedLanguageCode != nil ? "Automatisch erkannt" : "Von dir festgelegt") {
                PillPicker(selection: bindingForBookLanguage(), options: languageChoices(including: book.languageCode).map {
                    PillOption(value: $0, label: LanguageDetector.displayName($0))
                })
            }
            if book.mode == .summary {
                PillRow(title: "Sprache der Zusammenfassung", subtitle: "Vorgelesen wird in dieser Sprache — Stimme passend wählen.") {
                    PillPicker(selection: bindingForSummaryLanguage(), options:
                        [PillOption(value: String?.none, label: "Wie Original")] +
                        LanguageDetector.selectableLanguages.map { PillOption(value: String?.some($0), label: LanguageDetector.displayName($0)) })
                }
            }
            if let previewError = voicePreview.errorMessage {
                Text(previewError).flowFont(.caption).foregroundStyle(.red).padding(.horizontal, 6)
            }
        }
        .sheet(isPresented: $showVoiceGallery) {
            VoiceGalleryView(
                onSelect: { voiceID in
                    update {
                        $0.engineID = voiceID.engine
                        $0.voice = voiceID.voice
                    }
                },
                currentVoice: VoiceID(engine: book.engineID, voice: book.voice),
                languageCode: book.outputLanguageCode,
                previewText: RevoiceSheet.previewPassage(of: book, settings: settingsStore.settings)
            )
        }
    }

    /// Narrator card: who reads this book, with direct choice + gallery.
    private var voiceCard: some View {
        let profile = VoiceCatalog.profile(for: VoiceID(engine: book.engineID, voice: book.voice))
        let voices = TTSEngineFactory.availableVoices(for: book.engineID)
        return HStack(spacing: 16) {
            Image(systemName: "person.wave.2.fill")
                .appFont(size: 18)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Sprecher:in")
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(profile?.displayName ?? voices.first(where: { $0.id == book.voice })?.displayName ?? book.voice)
                    .flowFont(.title3)
                HStack(spacing: 6) {
                    StatusBadge(text: book.engineID.shortName, systemImage: "cpu", tint: .secondary)
                    if let profile {
                        StatusBadge(text: profile.speed.label, systemImage: "hare")
                    }
                }
            }
            Spacer(minLength: 12)
            Menu {
                Section("Engine") {
                    ForEach(TTSEngineID.allCases) { engine in
                        Button {
                            update { $0.engineID = engine }
                            if let first = TTSEngineFactory.availableVoices(for: engine).first,
                               !TTSEngineFactory.availableVoices(for: engine).contains(where: { $0.id == book.voice }) {
                                update { $0.voice = first.id }
                            }
                        } label: {
                            if engine == book.engineID { Label(engine.shortName, systemImage: "checkmark") } else { Text(engine.shortName) }
                        }
                    }
                }
                Section("Stimme") {
                    ForEach(voices) { voice in
                        Button {
                            update { $0.voice = voice.id }
                        } label: {
                            if voice.id == book.voice { Label(voice.displayName, systemImage: "checkmark") } else { Text(voice.displayName) }
                        }
                    }
                }
                Divider()
                Button("In der Galerie durchhören …") { showVoiceGallery = true }
            } label: {
                Text("Ändern")
                    .flowFont(.body, weight: .semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.tint.opacity(0.13)))
                    .foregroundStyle(.tint)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(18)
        .flowSurface(cornerRadius: Theme.Radius.row)
    }

    @ViewBuilder
    private var previewButton: some View {
        Button {
            if voicePreview.isPlaying || voicePreview.isGenerating {
                voicePreview.stop()
            } else if let sampleText = book.sortedChapters.first(where: { !$0.textForNarration.isEmpty })?.textForNarration {
                voicePreview.preview(text: sampleText, engineID: book.engineID, voice: book.voice, speed: book.speechSpeed, settings: settingsStore.settings)
            }
        } label: {
            if voicePreview.isGenerating {
                Label("Erzeuge Probe …", systemImage: "waveform")
            } else if voicePreview.isPlaying {
                Label("Stopp", systemImage: "stop.fill")
            } else {
                Label("Probe hören", systemImage: "play.fill")
            }
        }
        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .large))
        .disabled(book.chapters.isEmpty)
    }

    private var granularitySection: some View {
        PillSection(book.mode == .transcription ? "Kapitel & Track-Größe" : "KI-Portionierung") {
            VStack(alignment: .leading, spacing: 16) {
                if book.mode == .transcription {
                    transcriptionGranularityContent
                } else {
                    summaryGranularityContent
                }
            }
            .padding(18)
            .flowSurface(cornerRadius: Theme.Radius.card)
        }
    }

    private var transcriptionGranularityContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bündelt Abschnitte zu Hörbuch-Tracks. Änderungen wirken sofort auf die Kapitel unten.")
                    .flowFont(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if book.targetChapterCharacters != nil && book.targetChapterCharacters != 0 {
                    Button("Original-Gliederung") { updateTargetChapterCharacters(0) }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                }
            }
            HStack(spacing: 16) {
                Slider(value: bindingForTargetChapterCharacters(), in: 2000...40000, step: 1000)
                Text(effectiveTargetChapterCharacters == 0 ? "Original" : "\(formatNumber(effectiveTargetChapterCharacters)) Zeichen")
                    .flowFont(.body, weight: .semibold)
                    .monospacedDigit()
                    .frame(width: 130, alignment: .trailing)
            }
            HStack(spacing: 12) {
                statCard(title: "Kapitel", value: "\(book.chapters.count)", detail: book.rawImportedChapters.map { String(localized: "\($0.count) im Original") } ?? "")
                statCard(title: "Ø Länge", value: "\(formatNumber(averageChapterCharacters))", detail: String(localized: "Zeichen · ca. \(formatNumber(averageChapterCharacters / 6)) Wörter"))
                statCard(title: "Pro Track", value: formatDuration(minutes: estimatedMinutesPerChapter), detail: L("bei normalem Tempo"))
                statCard(title: "Gesamt", value: formatDuration(minutes: estimatedTotalMinutes), detail: String(format: L("bei %.2f× Tempo"), book.speechSpeed))
            }
        }
    }

    private var summaryGranularityContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wie viel Text das Sprachmodell pro Aufruf liest. Kleiner = detailtreuer, größer = mehr Zusammenhang.")
                    .flowFont(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if book.summarizationBudget != nil {
                    Button("Standard") { updateSummarizationBudget(nil) }
                        .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
                }
            }
            HStack(spacing: 16) {
                Slider(value: bindingForSummarizationBudget(), in: 8000...70000, step: 2000)
                Text("\(formatNumber(effectiveSummarizationBudget)) Zeichen")
                    .flowFont(.body, weight: .semibold)
                    .monospacedDigit()
                    .frame(width: 130, alignment: .trailing)
            }
            let calls = plannedLLMCalls
            HStack(spacing: 12) {
                statCard(title: "KI-Aufrufe", value: "\(calls)", detail: String(localized: "\(settingsStore.settings.activeParallelRequests) parallel"))
                statCard(title: "Kontext", value: "\(formatNumber(totalCharacters / max(calls, 1)))", detail: "Zeichen · ~\(formatNumber(Int(Double(totalCharacters / max(calls, 1)) / 4.2))) Tokens")
                statCard(title: "Dauer", value: formatLLMDuration(calls: calls), detail: settingsStore.settings.llmProvider.displayName)
                statCard(title: "Eingang", value: "\(formatNumber(totalCharacters))", detail: "Zeichen · \(book.chapters.count) Abschnitte")
            }
            DisclosureGroup("Eingangs-Gliederung anpassen (\(book.chapters.count) Abschnitte)") {
                HStack(spacing: 16) {
                    Slider(value: bindingForTargetChapterCharacters(), in: 2000...40000, step: 1000)
                    Text(effectiveTargetChapterCharacters == 0 ? "Original" : "\(formatNumber(effectiveTargetChapterCharacters)) Zeichen")
                        .flowFont(.callout, weight: .semibold)
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                }
                .padding(.top, 6)
            }
            .flowFont(.callout)
        }
    }

    private func statCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).flowFont(.caption, weight: .medium).foregroundStyle(.secondary)
            Text(value)
                .flowFont(.title3)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !detail.isEmpty {
                Text(L(detail)).flowFont(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatDuration(minutes: Double) -> String {
        ListeningTimeFormatter.long(minutes * 60)
    }

    private func formatLLMDuration(calls: Int) -> String {
        let parallel = max(1, settingsStore.settings.activeParallelRequests)
        let totalSeconds = (Double(calls) * 16.0) / Double(parallel)
        let totalMins = Int(ceil(totalSeconds / 60.0))
        if totalMins <= 1 {
            return L("< 1 Min.")
        } else {
            return String(localized: "ca. \(totalMins) Min.")
        }
    }

    private var outputSection: some View {
        PillSection("Ausgabe", footer: "Ziel: " + (settingsStore.settings.outputBaseFolderPath as NSString).abbreviatingWithTildeInPath + "/" + settingsStore.settings.outputFolderTemplate.relativePath(title: book.title, author: book.author)) {
            PillRow(title: "Format") {
                SegmentedPills(selection: bindingForFormat(), options: [
                    PillOption(value: OutputFormat.m4b, label: "M4B-Hörbuch", shortLabel: "M4B"),
                    PillOption(value: OutputFormat.m4a, label: "M4A", shortLabel: "M4A"),
                    PillOption(value: OutputFormat.mp3Chapters, label: "MP3-Kapitel", shortLabel: "MP3"),
                ])
            }
        }
    }

    /// "Vorbereitung prüfen" (plan 6.7) as a compact proofreading card —
    /// visible at a glance instead of hidden in a disclosure.
    private var preparationSection: some View {
        let report = preparationReport ?? PreparationReport()
        return PillSection("Korrektur gelesen", footer: "Der gespeicherte Text bleibt unverändert — alle Regeln wirken nur auf das Vorgelesene.") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    proofItem("\(report.boxLabelOnlyLines + report.boxLabelPrefixes)", "Box-Labels", "tag")
                    proofItem("\(report.listItems)", "Aufzählungen", "list.bullet")
                    proofItem("\(report.headingNumbersStripped)", "Überschriften-Nummern", "number")
                    proofItem("\(report.tocSuggested)", "Verzeichnisse übersprungen", "speaker.slash")
                    if report.excludedByUser > 0 {
                        proofItem("\(report.excludedByUser)", "von dir ausgeschlossen", "person.crop.circle.badge.xmark")
                    }
                }
                if !report.suspiciousChapters.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Bitte ansehen: sehr kurz oder beginnt mitten im Satz", systemImage: "exclamationmark.bubble")
                            .flowFont(.callout, weight: .semibold)
                            .foregroundStyle(.orange)
                        ForEach(report.suspiciousChapters, id: \.self) { title in
                            Text("• \(title)").flowFont(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(18)
            .flowSurface(cornerRadius: Theme.Radius.card)
        }
    }

    private func proofItem(_ value: String, _ label: String, _ image: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: image).foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).flowFont(.headline).monospacedDigit()
                Text(L(label)).flowFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Inhalt")
                    .appFont(size: 24, weight: .semibold, design: .serif)
                Text("\(book.chapters.count) Kapitel")
                    .flowFont(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Titel anklicken zum Umbenennen · ziehen zum Umsortieren")
                    .flowFont(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    splitEditorTargetChapterID = nil
                    showSplitEditor = true
                } label: {
                    Label("Gliederung bearbeiten", systemImage: "book.pages")
                }
                .buttonStyle(FlowButtonStyle(variant: .secondary, size: .small))
            }
            // Sorted once per render (v4.2.3): before, every group heading
            // re-sorted all chapters — per row, with hundreds of chapters.
            let sorted = book.sortedChapters
            let groups = ChapterOutlineGroup.make(sorted)
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    if let title = group.title {
                        ChapterGroupHeader(title: title, chapters: sorted[group.range],
                                           collapsible: groups.count > 1, isExpanded: isExpanded(group, total: sorted.count)) {
                            toggle(group, total: sorted.count)
                        }
                    }
                    if group.title == nil || isExpanded(group, total: sorted.count) {
                        ForEach(group.range, id: \.self) { index in
                            let chapter = sorted[index]
                            ChapterRow(
                                chapter: chapter,
                                index: index,
                                onRename: { newTitle in renameChapter(id: chapter.id, title: newTitle) },
                                onMergeWithPrevious: index > 0 ? { mergeWithPrevious(chapterID: chapter.id) } : nil,
                                onDelete: sorted.count > 1 ? { deleteChapter(id: chapter.id) } : nil,
                                onSplit: {
                                    splitEditorTargetChapterID = chapter.id
                                    showSplitEditor = true
                                },
                                onToggleNarration: { included in setNarrationIncluded(chapterID: chapter.id, included: included) }
                            )
                            .id(chapter.id)
                            .draggable(chapter.id.uuidString)
                            .dropDestination(for: String.self) { droppedIDs, _ in
                                guard let draggedIDString = droppedIDs.first, let draggedID = UUID(uuidString: draggedIDString) else { return false }
                                moveChapter(draggedID: draggedID, toIndex: index)
                                return true
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .flowSurface(cornerRadius: Theme.Radius.card)
            .sheet(isPresented: $showSplitEditor) {
                ChapterSplitEditorView(bookID: bookID, targetChapterID: splitEditorTargetChapterID)
            }
        }
    }

    /// Long outlines (AI chapters often run into the hundreds) start
    /// collapsed into their groups; short ones are shown in full.
    private func isExpanded(_ group: ChapterOutlineGroup, total: Int) -> Bool {
        expandedGroups?.contains(group.id) ?? (total <= ChapterOutlineGroup.collapseThreshold)
    }

    private func toggle(_ group: ChapterOutlineGroup, total: Int) {
        var expanded = expandedGroups ?? (total <= ChapterOutlineGroup.collapseThreshold
            ? Set(ChapterOutlineGroup.make(book.sortedChapters).map(\.id)) : [])
        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
        withAnimation(.snappy) { expandedGroups = expanded }
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

    /// "Nicht vorlesen" per chapter (plan 6.2): the classification only
    /// suggests — this is the user's binding decision.
    private func setNarrationIncluded(chapterID: UUID, included: Bool) {
        update { book in
            if let index = book.chapters.firstIndex(where: { $0.id == chapterID }) {
                book.chapters[index].includeInNarration = included
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

/// A run of chapters under one heading (v4.2.3): the book's own groups
/// (AI outline), or — in long flat outlines — blocks of 25.
struct ChapterOutlineGroup: Identifiable, Equatable {
    static let collapseThreshold = 60
    static let blockSize = 25

    let id: String
    let title: String?
    let range: Range<Int>

    static func make(_ chapters: [Chapter]) -> [ChapterOutlineGroup] {
        guard !chapters.isEmpty else { return [] }
        if chapters.contains(where: { $0.groupTitle != nil }) {
            var groups: [ChapterOutlineGroup] = []
            var start = 0
            for index in 1...chapters.count where index == chapters.count || chapters[index].groupTitle != chapters[start].groupTitle {
                let title = chapters[start].groupTitle
                groups.append(ChapterOutlineGroup(id: "\(start)-\(title ?? "")", title: title, range: start..<index))
                start = index
            }
            return groups
        }
        guard chapters.count > collapseThreshold else {
            return [ChapterOutlineGroup(id: "all", title: nil, range: 0..<chapters.count)]
        }
        return stride(from: 0, to: chapters.count, by: blockSize).map { start in
            let end = min(start + blockSize, chapters.count)
            return ChapterOutlineGroup(id: "block-\(start)", title: String(format: L("Kapitel %d–%d"), start + 1, end), range: start..<end)
        }
    }
}

/// Group heading: title, how many chapters, how long; collapsible.
private struct ChapterGroupHeader: View {
    let title: String
    let chapters: ArraySlice<Chapter>
    let collapsible: Bool
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                if collapsible {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                }
                Text(title)
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(format: L("%d Kapitel"), chapters.count) + " · " + ChapterRow.minutesLabel(chapters.reduce(0) { $0 + $1.cleanedText.utf8.count }))
                    .flowFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let index: Int
    var onRename: (String) -> Void
    var onMergeWithPrevious: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSplit: (() -> Void)?
    var onToggleNarration: (Bool) -> Void

    /// nil = user hasn't decided yet; the classification's suggestion
    /// (TOC/front matter) is shown as a soft hint.
    private var narrationExcluded: Bool {
        if let included = chapter.includeInNarration { return !included }
        return chapter.matterKind.map(FrontBackMatterClassifier.suggestsSkipping) ?? false
    }

    @State private var title: String = ""
    @State private var hovering = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ZStack(alignment: .trailing) {
                // Drag handle on hover, number otherwise.
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(hovering && !editing ? 1 : 0)
                    .help("Ziehen zum Umsortieren")
                Text("\(index + 1)")
                    .flowFont(.caption, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(hovering && !editing ? 0 : 1)
            }
            .frame(width: 30, alignment: .trailing)
            HStack(spacing: 6) {
                TextField("Kapiteltitel", text: $title)
                    .textFieldStyle(.plain)
                    .appFont(size: 14, design: .serif)
                    .strikethrough(narrationExcluded, color: .secondary)
                    .foregroundStyle(narrationExcluded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .focused($editing)
                    .onSubmit(commit)
                    .onExitCommand { title = chapter.title; editing = false }
                if hovering && !editing {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            // A visible field on hover and while editing (v4.2.3): before,
            // nothing showed that the title is editable.
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(editing ? 0.07 : (hovering ? 0.035 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.tint.opacity(editing ? 0.6 : 0), lineWidth: 1))
            .help("Klicken zum Umbenennen · Enter übernimmt, Esc verwirft")
            .layoutPriority(1)
            if narrationExcluded {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(.orange)
                    .help("Wird nicht vorgelesen\(chapter.includeInNarration == nil ? " (Vorschlag der automatischen Erkennung — z. B. Inhaltsverzeichnis/Titelei)" : "")")
            }
            DottedLeader().frame(minWidth: 16)
            // Fixed width (v4.2.3): it used to wrap one character per line.
            Text(Self.minutesLabel(chapter.cleanedText.utf8.count))
                .flowFont(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Menu {
                if let included = chapter.includeInNarration {
                    if included {
                        Button("Nicht vorlesen", action: { onToggleNarration(false) })
                    } else {
                        Button("Wieder vorlesen", action: { onToggleNarration(true) })
                    }
                } else {
                    Button("Nicht vorlesen", action: { onToggleNarration(false) })
                    Button("Auf jeden Fall vorlesen", action: { onToggleNarration(true) })
                }
                Button("Umbenennen") { editing = true }
                if let onSplit {
                    Button("Kapitel teilen …", action: onSplit)
                }
                if let onMergeWithPrevious {
                    Button("Mit vorherigem zusammenführen", action: onMergeWithPrevious)
                }
                if let onDelete {
                    Divider()
                    Button("Löschen", role: .destructive, action: onDelete)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.35)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.03 : 0)))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        // Showing a row no longer writes the book (v4.2.3): the title is
        // only saved when an edit is committed — before, every row that
        // scrolled into view saved the whole library.
        .onAppear { title = chapter.title }
        .onChange(of: chapter.title) { _, newValue in if !editing { title = newValue } }
        .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != chapter.title else {
            title = chapter.title
            return
        }
        onRename(trimmed)
    }

    /// Bytes of text → spoken minutes (≈ 1000 UTF-8 bytes per minute; the
    /// byte count is O(1), unlike counting characters).
    static func minutesLabel(_ utf8Bytes: Int) -> String {
        let minutes = Double(utf8Bytes) / 1000
        if minutes < 1 { return L("< 1 Min.") }
        if minutes >= 90 { return String(format: L("%d Std. %d Min."), Int(minutes) / 60, Int(minutes) % 60) }
        return String(format: L("%d Min."), Int(minutes.rounded()))
    }
}
