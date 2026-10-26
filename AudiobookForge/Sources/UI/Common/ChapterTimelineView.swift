import SwiftUI

/// Horizontal timeline: one segment per chapter, width proportional to its
/// (actual once known, else estimated from text length) duration, colored by
/// synthesis status. Gives an at-a-glance sense of how far along a book is
/// and where in the book a failure happened.
///
/// v4.3: when a book has so many chapters that the bar no longer fits (AI
/// chapters often run into the hundreds), it used to run out of the window.
/// Now it becomes the neck of a very long dog: body at the start, head at
/// the end, scrollable, following the progress — and the head can be petted.
struct ChapterTimelineView: View {
    let chapters: [Chapter]
    @Environment(\.flowAccent) private var accent
    @Environment(SettingsStore.self) private var settingsStore

    static let minSegment: CGFloat = 3
    static let spacing: CGFloat = 2

    struct TimelineItem: Identifiable {
        let id: UUID
        let index: Int
        let title: String
        let status: ChapterAudioStatus
        let weight: CGFloat
    }

    private var items: [TimelineItem] {
        let sorted = chapters.sorted { $0.order < $1.order }
        guard !sorted.isEmpty else { return [] }
        // Fast estimate without calling textForNarration which runs heavy regex stripping
        let estimates: [Double] = sorted.map { ch in
            ch.audioDurationSeconds ?? (Double(ch.cleanedText.utf8.count) / 15.0)
        }
        let total = estimates.reduce(0.0) { $0 + max($1, 1.0) }
        guard total > 0 else { return [] }
        return sorted.enumerated().map { index, ch in
            TimelineItem(id: ch.id, index: index, title: ch.title, status: ch.audioStatus,
                         weight: CGFloat(max(estimates[index], 1.0) / total))
        }
    }

    /// Smallest width the bar needs: every chapter at least `minSegment`.
    static func naturalWidth(count: Int) -> CGFloat {
        CGFloat(count) * minSegment + CGFloat(max(count - 1, 0)) * spacing
    }

    @State private var width: CGFloat = 0

    var body: some View {
        let list = items
        let dog = settingsStore.settings.lesserDogEnabled && width > 0 && Self.naturalWidth(count: list.count) > width
        VStack(alignment: .leading, spacing: 0) {
            // Measures the space offered, not the (possibly overflowing) bar.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if dog {
                LesserDogTimeline(items: list, color: color(for:))
            } else {
                bar(list, width: width)
            }
        }
    }

    private func bar(_ list: [TimelineItem], width: CGFloat) -> some View {
        let totalSpacing = Self.spacing * CGFloat(max(list.count - 1, 0))
        let availableWidth = max(width - totalSpacing, 0)
        return HStack(spacing: Self.spacing) {
            ForEach(list) { item in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color(for: item.status))
                    .frame(width: max(availableWidth * item.weight, Self.minSegment))
                    .help(item.title)
            }
        }
        .frame(height: 12)
    }

    private func color(for status: ChapterAudioStatus) -> Color {
        switch status {
        case .pending: return Color.secondary.opacity(0.25)
        case .summarizing, .synthesizing: return accent.color.opacity(0.5)
        case .ready: return accent.color
        case .failed: return .red
        }
    }
}

/// The long dog (v4.3). Our own pixel dog, a nod to a certain very good boy.
struct LesserDogTimeline: View {
    let items: [ChapterTimelineView.TimelineItem]
    let color: (ChapterAudioStatus) -> Color

    static let pixel: CGFloat = 4

    @Environment(FunCenter.self) private var fun: FunCenter?
    @State private var hearts: [UUID] = []
    @State private var bounce = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal) {
                    // Head first (visible, can be petted), then the neck —
                    // the chapter bar — and the rest of the dog at the far end.
                    HStack(alignment: .top, spacing: 0) {
                        head
                            .id("head")
                        neck
                            .padding(.top, 4 * Self.pixel)
                        FunSprite(rows: Sprites.mirrored(Sprites.dogBody), pixel: Self.pixel)
                            .padding(.top, 4 * Self.pixel)
                            .id("tail")
                    }
                    .padding(.trailing, 24)
                }
                // The neck still runs past the card and out of the window —
                // that was the joke from the start; now it can be followed.
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                HStack(spacing: 10) {
                    Text(String(format: L("%d Kapitel — der Hund hat einen sehr langen Hals. Kopf antippen zum Streicheln."), items.count))
                        .flowFont(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.easeInOut(duration: 1.2)) { proxy.scrollTo("head", anchor: .leading) }
                    } label: { Label("Zum Kopf", systemImage: "arrow.left") }
                    Button {
                        withAnimation(.easeInOut(duration: 1.2)) { proxy.scrollTo("tail", anchor: .trailing) }
                    } label: { Label("Zum Schwanz", systemImage: "arrow.right") }
                }
                .buttonStyle(FlowButtonStyle(variant: .subtle, size: .small))
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugAutomation.navigate)) { note in
                if let target = (note.userInfo as? [String: String])?["dogScroll"] { proxy.scrollTo(target, anchor: target == "tail" ? .trailing : .leading) }
            }
            #endif
        }
    }

    /// The neck: a white band with an outline, the chapter bar inside.
    private var neck: some View {
        HStack(spacing: ChapterTimelineView.spacing) {
            ForEach(items) { item in
                Rectangle()
                    .fill(color(item.status))
                    .frame(width: max(ChapterTimelineView.minSegment, item.weight * CGFloat(items.count) * 5))
                    .help(item.title)
                    .id(item.index)
            }
        }
        .frame(height: 4 * Self.pixel)
        .padding(.horizontal, 2)
        .background(Color(white: 0.98))
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.12)).frame(height: Self.pixel) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.12)).frame(height: Self.pixel) }
        .padding(.vertical, 0)
        .frame(height: 6 * Self.pixel, alignment: .center)
        .background(Color(white: 0.98).padding(.vertical, Self.pixel))
    }

    private var head: some View {
        ZStack(alignment: .top) {
            FunSprite(rows: Sprites.mirrored(Sprites.dogHead), pixel: Self.pixel)
                .rotationEffect(.degrees(bounce ? 8 : 0), anchor: .bottomTrailing)
                .scaleEffect(bounce ? 1.08 : 1, anchor: .bottomTrailing)
            ForEach(hearts, id: \.self) { id in
                FloatingHeart(id: id) { hearts.removeAll { $0 == id } }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { pet() }
        .help(L("Streicheln"))
        .accessibilityLabel(L("Hund streicheln"))
        .accessibilityAddTraits(.isButton)
    }

    private func pet() {
        fun?.petDog()
        hearts.append(UUID())
        withAnimation(.spring(response: 0.18, dampingFraction: 0.4)) { bounce = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { bounce = false }
        }
    }
}

private struct FloatingHeart: View {
    let id: UUID
    var onDone: () -> Void
    @State private var rise = false

    var body: some View {
        FunSprite(rows: Sprites.heart, pixel: 2)
            .offset(x: CGFloat(abs(id.hashValue % 20)) - 4, y: rise ? -34 : 0)
            .opacity(rise ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { rise = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    onDone()
                }
            }
    }
}
