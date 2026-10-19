import SwiftUI

struct ProcessingView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    @Environment(\.colorScheme) private var colorScheme
    let bookID: UUID

    private var book: BookProject? { libraryStore.book(id: bookID) }

    var body: some View {
        if let book {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    workshopHeader(book)

                    if let error = book.lastErrorMessage, book.status == .paused || book.status == .failed {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Unterbrochen")
                                    .flowFont(.headline)
                                    .foregroundStyle(Color.orange)
                                Text(error)
                                    .flowFont(.callout)
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                    }

                    if let progress = pipelineController.progress[bookID] {
                        RunProgressPanel(progress: progress)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Inhalt")
                                .font(.system(size: 24, weight: .semibold, design: .serif))
                            let ready = book.chapters.filter { $0.audioStatus == .ready }.count
                            Text("\(ready) von \(book.chapters.count) Kapiteln eingesprochen")
                                .flowFont(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ChapterTimelineView(chapters: book.chapters)
                            .padding(14)
                            .flowSurface(cornerRadius: Theme.Radius.card)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(book.sortedChapters.enumerated()), id: \.element.id) { index, chapter in
                                ChapterProgressRow(index: index, chapter: chapter)
                            }
                        }
                        .padding(.vertical, 8)
                        .flowSurface(cornerRadius: Theme.Radius.card)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 26)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectHidden(true, for: .top)
        .scrollIndicators(.never)
            .navigationTitle(book.title)
        } else {
            EmptyStateCard(systemImage: "questionmark.folder", title: "Buch nicht gefunden")
        }
    }

    /// The book being made: its cover fills up like fresh ink.
    private func workshopHeader(_ book: BookProject) -> some View {
        let fraction = pipelineController.progress[bookID]?.overallFraction ?? 0
        let isRunning = pipelineController.isRunning(bookID)
        return HStack(alignment: .center, spacing: 26) {
            ZStack(alignment: .bottom) {
                BookCoverView(book: book, width: 130)
                    .saturation(0.25 + 0.75 * fraction)
                // Ink rising.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0), Color.white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 130, height: (130 / 0.72) * (1 - fraction))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .frame(width: 130, height: 130 / 0.72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                ProgressRing(fraction: fraction, lineWidth: 4)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.regularMaterial))
                    .offset(x: 14, y: 14)
            }
            .animation(.easeInOut(duration: 0.6), value: fraction)

            VStack(alignment: .leading, spacing: 8) {
                Text(book.status == .paused ? "In der Werkstatt · pausiert" : (isRunning ? "In der Werkstatt" : "Wird vorbereitet"))
                    .flowFont(.caption, weight: .semibold)
                    .foregroundStyle(book.status == .paused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint))
                    .textCase(.uppercase)
                    .tracking(1.1)
                Text(book.title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .lineLimit(3)
                if !book.author.isEmpty {
                    Text(book.author).flowFont(.title3, weight: .regular).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if book.status == .paused || book.status == .failed {
                        Button {
                            pipelineController.resumeProcessing(bookID: bookID)
                        } label: {
                            Label("Fortsetzen", systemImage: "play.fill")
                        }
                        .buttonStyle(FlowButtonStyle(variant: .prominent, size: .large))
                    } else if isRunning {
                        Button {
                            pipelineController.pauseProcessing(bookID: bookID)
                        } label: {
                            Label("Pausieren", systemImage: "pause.fill")
                        }
                        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .large))
                    }
                    Button(role: .destructive) {
                        pipelineController.cancelProcessing(bookID: bookID)
                    } label: {
                        Label("Abbrechen", systemImage: "xmark")
                    }
                    .buttonStyle(FlowButtonStyle(variant: .destructive, size: .large))
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ChapterProgressRow: View {
    let index: Int
    let chapter: Chapter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(chapter.audioStatus == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                if let error = chapter.lastError {
                    Text(error).flowFont(.caption).foregroundStyle(.red)
                }
            }
            .layoutPriority(1)
            DottedLeader().frame(minWidth: 16)
            if let duration = chapter.audioDurationSeconds {
                Text(ListeningTimeFormatter.clock(duration))
                    .flowFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Text("\(index + 1)")
                    .flowFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch chapter.audioStatus {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .summarizing, .synthesizing:
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}


/// Live run progress: overall bar with percent/ETA, phase stepper, the
/// current phase's details, and a tail of the run log. Refreshes once per
/// second for the elapsed/remaining clocks; everything else is driven by
/// `PipelineController.progress` updates.
private struct RunProgressPanel: View {
    let progress: RunProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int((progress.overallFraction * 100).rounded())) %")
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let total = progress.estimatedTotalRemainingSeconds {
                            Text("Fertig in ca. \(DurationFormatter.short(total))")
                                .font(.headline)
                            Text("um \(Date().addingTimeInterval(total).formatted(date: .omitted, time: .shortened)) Uhr")
                                .foregroundStyle(.secondary)
                        }
                        Text("Verstrichen \(DurationFormatter.short(progress.elapsed))")
                            .foregroundStyle(.secondary)
                        if let remaining = progress.estimatedRemainingSeconds {
                            Text("Aktuelle Phase noch ca. \(DurationFormatter.short(remaining))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
                FlowProgressBar(fraction: progress.overallFraction, height: 10)

                phaseStepper

                phaseDetails

                if !progress.recentLog.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(progress.recentLog.suffix(6).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(22)
            .flowSurface(cornerRadius: Theme.Radius.card)
        }
    }

    private var phaseStepper: some View {
        let currentIndex = progress.phases.firstIndex { $0.stage == progress.stage }
        return HStack(spacing: 6) {
            ForEach(Array(progress.phases.enumerated()), id: \.offset) { index, phase in
                let isDone = progress.stage == .done || (currentIndex.map { index < $0 } ?? false)
                let isCurrent = index == currentIndex
                HStack(spacing: 4) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(isDone || isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    Text(Self.bookPhaseName(phase.stage))
                        .flowFont(.callout, weight: isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
                if index < progress.phases.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1).frame(maxWidth: 24)
                }
            }
        }
    }

    @ViewBuilder
    private var phaseDetails: some View {
        switch progress.stage {
        case .describingImages:
            detailRow(title: "Bildpass", value: "\(progress.imagesDone) von \(progress.imagesTotal) Abbildungen", fraction: progress.phaseFraction)
        case .summarizing:
            VStack(alignment: .leading, spacing: 6) {
                detailRow(
                    title: "KI-Zusammenfassung",
                    value: progress.llmCallsTotal > 0
                        ? "\(progress.llmCallsDone)/\(progress.llmCallsTotal) Aufrufe · \(progress.llmCharactersDone / 1000)k/\(progress.llmCharactersTotal / 1000)k Zeichen"
                        : progress.detail,
                    fraction: progress.llmCallsTotal > 0 ? progress.phaseFraction : nil
                )
                if let tps = progress.llmTokensPerSecond {
                    Text(String(format: "Generierung: %.0f Tokens/s", tps))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .synthesizing:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(progress.sortedActiveChapters, id: \.index) { chapter in
                    detailRow(
                        title: "Kapitel \(chapter.index + 1)",
                        value: workerDetail(chapter),
                        fraction: chapter.fraction
                    )
                }
                HStack(spacing: 16) {
                    Text("Kapitel \(progress.chaptersCompleted) von \(progress.chapterCount) fertig")
                    Text("Audio: \(DurationFormatter.short(progress.producedAudioSeconds)) von ca. \(DurationFormatter.short(progress.estimatedTotalAudioSeconds))")
                    if let rtf = progress.realTimeFactor {
                        Text(String(format: "%.1f× Echtzeit", 1 / max(rtf, 0.001)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        case .packaging:
            detailRow(title: "Verpacken", value: progress.detail, fraction: nil)
        default:
            if !progress.detail.isEmpty { Text(progress.detail).font(.callout) }
        }
    }

    /// The making of a book, in book words.
    static func bookPhaseName(_ stage: PipelineStage) -> String {
        switch stage {
        case .extracting: return L("Lesen")
        case .describingImages: return L("Bilder")
        case .summarizing: return L("Verdichten")
        case .synthesizing: return L("Einsprechen")
        case .packaging: return L("Binden")
        case .done: return L("Fertig")
        case .failed: return L("Fehler")
        }
    }

    private func workerDetail(_ chapter: RunProgress.ChapterProgress) -> String {
        var parts = [chapter.title]
        if let planned = chapter.plannedSegments {
            parts.append("Segment \(chapter.segmentsDone)/\(planned)")
        }
        return parts.joined(separator: " · ")
    }

    private func detailRow(title: String, value: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L(title)).flowFont(.body, weight: .semibold)
                Text(value).flowFont(.body).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let fraction {
                    Text("\(Int((fraction * 100).rounded())) %").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let fraction {
                FlowProgressBar(fraction: fraction, height: 5)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.accentColor)
            }
        }
    }
}
