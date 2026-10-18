import SwiftUI

/// Shows the text actually being narrated (transcription or summary,
/// whichever was used for TTS) with the currently-playing sentence
/// highlighted and auto-scrolled into view — a karaoke-style follow-along
/// for the built-in player. Falls back to plain, unhighlighted text when no
/// segment timing is available for this chapter (never an error).
struct ReadAlongView: View {
    let fullText: String
    let segments: [TTSSegment]
    let currentTime: Double

    private var currentSegmentIndex: Int? {
        segments.first { currentTime >= $0.startSeconds && currentTime < $0.startSeconds + $0.durationSeconds }?.index
    }

    /// Segments without any recovered sentence text (can happen for Kokoro
    /// when its internal chunking didn't line up 1:1 with our own sentence
    /// split) aren't useful to render individually — fall back to plain text.
    private var hasUsableSegmentText: Bool {
        segments.contains { ($0.text ?? "").isEmpty == false }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if segments.isEmpty || !hasUsableSegmentText {
                        Text(fullText)
                            .textSelection(.enabled)
                            .padding(16)
                    } else {
                        ForEach(segments, id: \.index) { segment in
                            segmentText(segment)
                                .id(segment.index)
                                .padding(.vertical, 2)
                        }
                        .padding(16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentSegmentIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func segmentText(_ segment: TTSSegment) -> some View {
        let text = Text((segment.text ?? "…") + " ")
        if segment.index == currentSegmentIndex {
            text
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        } else {
            text.foregroundStyle(.primary)
        }
    }
}
