import SwiftUI

/// Above this combined word count, computing a word-level diff risks a
/// multi-second UI stall (Myers-diff cost grows with edit distance, which is
/// large here since summarization removes most content) — fall back to
/// plain side-by-side text instead of hanging. Declared at file scope (not
/// on the View) so it's reachable from the background `Task.detached` that
/// computes the diff without hopping through the main actor.
private let wordDiffSizeLimit = 12000

/// Shows a chapter's original extracted text next to its summarized
/// (narrated) text, with word-level highlighting of what survived — lets
/// the user actually see what got cut and how aggressively, instead of
/// trusting the summarizer blindly.
struct SummaryDiffView: View {
    let chapterTitle: String
    let originalText: String
    let summaryText: String

    @State private var diffResult: TextDiffer.Result?
    @State private var isTooLargeForWordDiff = false
    @State private var isComputing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isComputing {
                ProgressView("Vergleiche Texte …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // An open book: original on the left page, summary on the right.
                HStack(spacing: 0) {
                    column(title: "Original") { originalColumn }
                    LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.14), Color.black.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 26)
                    column(title: "Zusammenfassung (vorgelesen)") { summaryColumn }
                }
            }
        }
        .resizableSheet(preferred: CGSize(width: 900, height: 640), floor: CGSize(width: 640, height: 460))
        .background { PaperPage() }
        .task { computeDiff() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapterTitle).appFont(size: 20, weight: .semibold, design: .serif)
                Text("\(originalText.count) → \(summaryText.count) Zeichen (\(ratioText))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isTooLargeForWordDiff {
                Label("Kapitel zu lang für Wort-Diff — unformatierter Vergleich", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Grau/durchgestrichen = im jeweils anderen Text nicht vorhanden", systemImage: "paintpalette")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var ratioText: String {
        guard !originalText.isEmpty else { return "0%" }
        return "\(Int(Double(summaryText.count) / Double(originalText.count) * 100))%"
    }

    private func column(title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title))
                .flowFont(.caption, weight: .semibold)
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .tracking(1)
                .padding([.horizontal, .top], 22)
            ScrollView {
                body()
                    .appFont(size: 14, design: .serif)
                    .lineSpacing(5)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(minWidth: 320)
    }

    @ViewBuilder
    private var originalColumn: some View {
        if let diffResult {
            wrappedTokens(diffResult.original)
        } else {
            Text(originalText)
        }
    }

    @ViewBuilder
    private var summaryColumn: some View {
        if let diffResult {
            wrappedTokens(diffResult.summary)
        } else {
            Text(summaryText)
        }
    }

    private func wrappedTokens(_ tokens: [TextDiffer.Token]) -> some View {
        tokens.reduce(Text("")) { partial, token in
            let piece: Text
            if token.kept {
                piece = Text(token.text + " ")
            } else {
                piece = Text(token.text + " ")
                    .foregroundColor(.secondary)
                    .strikethrough(true, color: .secondary)
            }
            return partial + piece
        }
    }

    private func computeDiff() {
        let original = originalText
        let summary = summaryText
        Task.detached(priority: .userInitiated) {
            let originalWordCount = original.split(whereSeparator: { $0.isWhitespace }).count
            let summaryWordCount = summary.split(whereSeparator: { $0.isWhitespace }).count
            let tooLarge = originalWordCount + summaryWordCount > wordDiffSizeLimit

            let result = tooLarge ? nil : TextDiffer.diff(original: original, summary: summary)
            await MainActor.run {
                self.isTooLargeForWordDiff = tooLarge
                self.diffResult = result
                self.isComputing = false
            }
        }
    }
}
