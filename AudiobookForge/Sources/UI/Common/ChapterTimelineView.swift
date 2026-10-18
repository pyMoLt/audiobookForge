import SwiftUI

/// Horizontal timeline: one segment per chapter, width proportional to its
/// (actual once known, else estimated from text length) duration, colored by
/// synthesis status. Gives an at-a-glance sense of how far along a book is
/// and where in the book a failure happened.
struct ChapterTimelineView: View {
    let chapters: [Chapter]

    private struct TimelineItem: Identifiable {
        let id: UUID
        let title: String
        let status: ChapterAudioStatus
        let weight: CGFloat
    }

    private var items: [TimelineItem] {
        let sorted = chapters.sorted { $0.order < $1.order }
        guard !sorted.isEmpty else { return [] }
        // Fast estimate without calling textForNarration which runs heavy regex stripping
        let estimates: [Double] = sorted.map { ch in
            ch.audioDurationSeconds ?? (Double(ch.cleanedText.count) / 15.0)
        }
        let total = estimates.reduce(0.0) { $0 + max($1, 1.0) }
        guard total > 0 else { return [] }
        return sorted.enumerated().map { index, ch in
            TimelineItem(
                id: ch.id,
                title: ch.title,
                status: ch.audioStatus,
                weight: CGFloat(max(estimates[index], 1.0) / total)
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let list = items
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(max(list.count - 1, 0))
            let availableWidth = max(geometry.size.width - totalSpacing, 0)

            HStack(spacing: spacing) {
                ForEach(list) { item in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: item.status))
                        .frame(width: max(availableWidth * item.weight, 3))
                        .help(item.title)
                }
            }
        }
        .frame(height: 12)
    }

    private func color(for status: ChapterAudioStatus) -> Color {
        switch status {
        case .pending: return Color.secondary.opacity(0.25)
        case .summarizing, .synthesizing: return .accentColor
        case .ready: return .green
        case .failed: return .red
        }
    }
}
