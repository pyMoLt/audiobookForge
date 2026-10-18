import SwiftUI

struct ProcessingView: View {
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(PipelineController.self) private var pipelineController
    let bookID: UUID

    private var book: BookProject? { libraryStore.book(id: bookID) }

    var body: some View {
        if let book {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).font(.title2.weight(.semibold))
                            HStack(spacing: 8) {
                                if let stage = book.currentStage {
                                    StageBadge(stage: stage)
                                }
                                if book.status == .paused {
                                    Text("Pausiert")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        Spacer()
                        if book.status == .paused || book.status == .failed {
                            Button {
                                pipelineController.resumeProcessing(bookID: bookID)
                            } label: {
                                Label("Fortsetzen", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        } else if pipelineController.isRunning(bookID) {
                            Button {
                                pipelineController.pauseProcessing(bookID: bookID)
                            } label: {
                                Label("Pausieren", systemImage: "pause.fill")
                            }
                        }
                        Button("Abbrechen", role: .destructive) {
                            pipelineController.cancelProcessing(bookID: bookID)
                        }
                    }
                    .padding(16)
                    .glassPanel()

                    if let error = book.lastErrorMessage, book.status == .paused || book.status == .failed {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unterbrochen")
                                    .font(.subheadline.weight(.semibold))
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if let progress = pipelineController.progress[bookID] {
                        RunProgressPanel(progress: progress)
                    }

                    ChapterTimelineView(chapters: book.chapters)
                        .padding(12)
                        .glassPanel()

                    LazyVStack(spacing: 0) {
                        ForEach(Array(book.sortedChapters.enumerated()), id: \.element.id) { index, chapter in
                            ChapterProgressRow(index: index, chapter: chapter)
                            if index < book.chapters.count - 1 { Divider() }
                        }
                    }
                    .glassPanel()
                }
                .padding(24)
            }
            .navigationTitle(book.title)
        } else {
            ContentUnavailableView("Buch nicht gefunden", systemImage: "questionmark.folder")
        }
    }
}

private struct ChapterProgressRow: View {
    let index: Int
    let chapter: Chapter

    var body: some View {
        HStack {
            statusIcon
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1). \(chapter.title)")
                if let error = chapter.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if let duration = chapter.audioDurationSeconds {
                Text(formatted(duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch chapter.audioStatus {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .summarizing, .synthesizing:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func formatted(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
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
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
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
                ProgressView(value: progress.overallFraction)
                    .progressViewStyle(.linear)

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
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
            .glassPanel()
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
                        .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary))
                    Text(phase.stage.displayName)
                        .font(.caption.weight(isCurrent ? .semibold : .regular))
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
                detailRow(
                    title: "Kapitel \(progress.chapterIndex + 1) von \(progress.chapterCount)",
                    value: progress.chapterTitle,
                    fraction: progress.chapterFraction
                )
                HStack(spacing: 16) {
                    Text("Audio: \(DurationFormatter.short(progress.producedAudioSeconds)) von ca. \(DurationFormatter.short(progress.estimatedTotalAudioSeconds))")
                    if let planned = progress.plannedSegments {
                        Text("Segment \(progress.segmentsDone)/\(planned)")
                    }
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

    private func detailRow(title: String, value: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let fraction {
                    Text("\(Int((fraction * 100).rounded())) %").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }
}
