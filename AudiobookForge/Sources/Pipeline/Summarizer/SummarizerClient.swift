import Foundation

enum SummarizerError: LocalizedError {
    case endpointUnreachable(String)
    case badResponse(String)
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let reason):
            return "Lokaler LLM-Endpoint nicht erreichbar: \(reason)"
        case .badResponse(let reason):
            return "Unerwartete Antwort vom LLM-Endpoint: \(reason)"
        case .emptyCompletion:
            return "Der LLM-Endpoint hat eine leere Antwort geliefert."
        }
    }
}

/// Talks to any OpenAI-compatible chat-completion endpoint (LM Studio,
/// Ollama's /v1 shim, etc.). The pipeline never hardcodes a specific server —
/// swapping providers is purely a matter of changing the base URL in Settings.
struct SummarizerClient: Sendable {
    let settings: AppSettings

    func testConnection() async -> Result<[String], Error> {
        do {
            let models = try await LLMClient(settings: settings).listModels()
            return .success(models.map(\.id))
        } catch {
            return .failure(error)
        }
    }

    /// Structured progress of a summarization run, for the progress UI.
    struct Progress: Sendable {
        var completedCalls: Int
        var totalCalls: Int
        var completedCharacters: Int
        var totalCharacters: Int
        var lastTokensPerSecond: Double?
    }

    /// One resulting audiobook chapter from an AI-summarization run: either
    /// a whole original chapter (no headings found in its batch's response),
    /// or one of several sub-chapters the model itself split its condensed
    /// text into via "## heading" markers.
    struct AIChapterResult: Sendable, Equatable {
        let title: String
        /// The original parent chapter this AI heading belongs to (books
        /// only — plan 7.3). Kept separate from `title` so the UI can show
        /// a hierarchy and packaging builds "Gruppe — Titel" names.
        var groupTitle: String?
        /// The original (pre-summarization) source text this came from —
        /// shared verbatim by every result derived from the same batch, since
        /// the model both compresses and reorganizes, so there's no exact
        /// substring of the input that maps to just one of its headings.
        /// Used for the original-vs-summary diff view.
        let sourceText: String
        var summarizedText: String
    }

    /// Turns a document's original (fine-grained, extraction-time) chapters
    /// into the final AI-mode chapter list. Original chapters are grouped
    /// into batches (see `buildBatches`) and each batch is sent as ONE
    /// request; the model is asked to insert its own "## heading" markers at
    /// natural topic changes as it condenses, and those headings — not the
    /// original chapter boundaries — become the actual chapter list. This
    /// deliberately gives up an exact per-input-chapter mapping (no ID
    /// tagging, no verbatim-title echo) in exchange for letting the model
    /// organize the compressed content the way it actually reads once
    /// condensed — the original fine-grained PDF/EPUB-outline split is often
    /// too granular or slightly mislabeled to begin with. If a batch's
    /// response has no headings at all, it becomes one (coarser) chapter —
    /// content is never lost, only navigation granularity degrades.
    ///
    /// `documentType == .book` never combines more than one original chapter
    /// into a single call (see `buildBatches`), so the known original
    /// chapter title is always used as a prefix for that call's AI-derived
    /// sub-chapters, keeping a book's real chapter names intact as the
    /// top-level structure.
    func summarizeIntoChapters(
        bookTitle: String,
        chapters: [(title: String, text: String)],
        documentType: DocumentType,
        characterBudget: Int? = nil,
        contextWindow: Int? = nil,
        outputLanguage: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil,
        onStructuredProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [AIChapterResult] {
        let budget = characterBudget ?? settings.summarizationChunkCharacterBudget
        let batches = Self.buildBatches(chapters: chapters, documentType: documentType, budget: budget, tolerance: settings.summarizationBatchTolerance)

        // Flatten into independent work items (one LLM call each, before any
        // length-retry splitting) so they can run concurrently while the
        // final chapter order is still exactly the batch/piece order.
        struct WorkItem: Sendable {
            let order: Int
            let batchNumber: Int
            let chapterCount: Int
            let parentTitle: String
            let piece: String
            let label: String
            /// Continuity context (plan 7.4): tail of the previous piece's
            /// SOURCE within the same batch, `nil` for a batch's first piece
            /// and for pieces starting at a real topic boundary.
            let context: String?
        }
        var items: [WorkItem] = []
        let useContinuity = settings.aiChapterContinuityEnabled
        for (batchNumber, indices) in batches.enumerated() {
            let batchChapters = indices.map { chapters[$0] }
            let combinedRaw = batchChapters.map(\.text).joined(separator: "\n\n")
            // A batch can still come out oversized (a solo chapter bigger
            // than the cap, or one very long book chapter) — split it at
            // paragraph boundaries so each call stays within budget.
            let pieces = combinedRaw.count > budget ? Self.chunk(text: combinedRaw, maxCharacters: budget) : [combinedRaw]
            var previousPiece: String?
            for (pieceIndex, piece) in pieces.enumerated() {
                let pieceLabel = pieces.count > 1 ? " (Teil \(pieceIndex + 1)/\(pieces.count))" : ""
                let context = useContinuity && pieceIndex > 0 && previousPiece != nil && !Self.startsWithTopicBoundary(piece)
                    ? Self.contextTail(of: previousPiece!) : nil
                items.append(WorkItem(order: items.count, batchNumber: batchNumber, chapterCount: indices.count, parentTitle: batchChapters[0].title, piece: piece, label: "Abschnitt \(batchNumber + 1)/\(batches.count)\(pieceLabel)", context: context))
                previousPiece = piece
            }
        }

        let totalCharacters = items.reduce(0) { $0 + $1.piece.count }
        let progressState = LockedBox(Progress(completedCalls: 0, totalCalls: items.count, completedCharacters: 0, totalCharacters: totalCharacters))
        onStructuredProgress?(progressState.withLock { $0 })
        let parallel = min(PowerProfile.current.llmRequests(configured: settings.activeParallelRequests), max(1, items.count))
        onProgress?("\(items.count) LLM-Aufruf(e) geplant, \(parallel) parallel, Thinking: \(settings.activeGenerationOptions.thinkingMode.displayName).")

        let llm = LLMClient(settings: settings)
        let responses: [Int: [String]] = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var next = 0
            var collected: [Int: [String]] = [:]
            func launch(_ item: WorkItem) {
                group.addTask {
                    onProgress?("Fasse \(item.label) zusammen (\(item.chapterCount) Kapitel, ~\(item.piece.count / 1000)k Zeichen) …")
                    let texts = try await self.summarizePiece(item.piece, bookTitle: bookTitle, outputLanguage: outputLanguage, llm: llm, contextWindow: contextWindow, label: item.label, depth: 0, context: item.context, onProgress: onProgress) { tps in
                        progressState.withLock { $0.lastTokensPerSecond = tps }
                    }
                    let snapshot = progressState.withLock { state -> Progress in
                        state.completedCalls += 1
                        state.completedCharacters += item.piece.count
                        return state
                    }
                    onStructuredProgress?(snapshot)
                    return (item.order, texts)
                }
            }
            while next < items.count && next < parallel {
                launch(items[next]); next += 1
            }
            while let (order, texts) = try await group.next() {
                collected[order] = texts
                if next < items.count {
                    try Task.checkCancellation()
                    launch(items[next]); next += 1
                }
            }
            return collected
        }

        var results: [AIChapterResult] = []
        for item in items {
            for response in responses[item.order] ?? [] {
                results.append(contentsOf: aiChapters(from: response, item: (parentTitle: item.parentTitle, piece: item.piece), documentType: documentType, onProgress: onProgress))
            }
        }
        let merged = AIChapterMerger.merge(
            Self.splitOversizedChapters(results, maxCharacters: settings.aiChapterMaxCharacters, onProgress: onProgress),
            minCharacters: settings.minAIChapterCharacters
        )
        if merged.count != results.count {
            onProgress?("KI-Kapitel unter \(settings.minAIChapterCharacters) Zeichen zusammengeführt: \(results.count) → \(merged.count) Kapitel.")
        }
        return merged
    }

    /// Splits AI chapters longer than `maxCharacters` at paragraph
    /// boundaries into evenly sized parts titled "Titel (Teil k/n)".
    static func splitOversizedChapters(_ chapters: [AIChapterResult], maxCharacters: Int, onProgress: (@Sendable (String) -> Void)? = nil) -> [AIChapterResult] {
        guard maxCharacters > 0 else { return chapters }
        var result: [AIChapterResult] = []
        for chapter in chapters {
            let length = chapter.summarizedText.count
            guard length > maxCharacters else { result.append(chapter); continue }
            let partCount = Int((Double(length) / Double(maxCharacters)).rounded(.up))
            let parts = partition(chapter.summarizedText, into: partCount)
            guard parts.count > 1 else { result.append(chapter); continue }
            onProgress?("    -> Kapitel „\(chapter.title)“ (\(length) Zeichen) zu lang — in \(parts.count) Teile gegliedert.")
            for (index, part) in parts.enumerated() {
                result.append(AIChapterResult(title: "\(chapter.title) (Teil \(index + 1)/\(parts.count))", sourceText: chapter.sourceText, summarizedText: part))
            }
        }
        return result
    }

    /// One LLM call for `piece`. If the server cut the answer off
    /// (`finish_reason == "length"`), a truncated summary would silently
    /// drop the end of the section — instead the piece is halved at a
    /// paragraph boundary and each half summarized on its own (up to two
    /// levels deep). Returns one response per final sub-piece, in order.
    private func summarizePiece(_ piece: String, bookTitle: String, outputLanguage: String?, llm: LLMClient, contextWindow: Int?, label: String, depth: Int, context: String?, onProgress: (@Sendable (String) -> Void)?, onSpeed: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        try Task.checkCancellation()
        let sanitized = Self.sanitizeHeadingMarkers(piece)
        var prompt = fillTemplate(settings.promptTemplates.userPromptTemplate, text: sanitized, bookTitle: bookTitle)
        if let context, settings.aiChapterContinuityEnabled {
            prompt += "\n\n" + ResponsePostprocess.contextMarker + "\n" + context
        }
        if let outputLanguage {
            // Explicit target language overrides "same language as the source".
            prompt += "\n\nWrite the entire output, including the headings, in \(outputLanguage)."
        }
        let completion = try await llm.complete(system: settings.promptTemplates.systemPrompt, user: prompt, purpose: .summary, inputCharacters: prompt.count + settings.promptTemplates.systemPrompt.count, contextWindow: contextWindow)
        if let tps = completion.tokensPerSecond { onSpeed(tps) }

        // Defensive cleanup (plan 7.5): meta phrases, collapsed duplicate
        // headings, and an echoed continuity context never reach narration.
        var content = ResponsePostprocess.clean(completion.content, echoedContext: (context != nil && settings.aiChapterContinuityEnabled) ? context : nil)

        var stats = "\(content.count) Zeichen, \(String(format: "%.0f", completion.durationSeconds)) s"
        if let tokens = completion.completionTokens { stats += ", \(tokens) Tokens" }
        if let reasoning = completion.reasoningTokens, reasoning > 0 { stats += " (davon \(reasoning) Thinking)" }
        if let tps = completion.tokensPerSecond { stats += String(format: ", %.0f Tok/s", tps) }
        onProgress?("    -> \(label): Antwort erhalten (\(stats))")

        if let budget = settings.activeGenerationOptions.effectiveThinkingBudget,
           let reasoning = completion.reasoningTokens, reasoning >= budget {
            onProgress?("    ⚠︎ Thinking-Budget (\(budget)) ausgeschöpft — Antwort kann Denk-Reste enthalten. Budget erhöhen oder Thinking ausschalten.")
        }

        guard completion.wasTruncated else { return [content] }
        guard depth < 2, piece.count > 4000 else {
            onProgress?("    ⚠︎ \(label): Antwort wurde wegen Längenlimit abgeschnitten und kann nicht weiter geteilt werden — übernommen wie geliefert.")
            return [content]
        }
        onProgress?("    ⚠︎ \(label): Antwort am Längenlimit abgeschnitten — teile Abschnitt in zwei Hälften und fasse neu zusammen.")
        let halves = Self.halve(piece)
        var outputs: [String] = []
        for (index, half) in halves.enumerated() {
            // Continuity: the first half inherits the piece's context; the
            // second half bridges from the end of the first half's source.
            let halfContext: String?
            if settings.aiChapterContinuityEnabled {
                if index == 0 {
                    halfContext = context
                } else {
                    halfContext = Self.startsWithTopicBoundary(half) ? nil : Self.contextTail(of: halves[0])
                }
            } else {
                halfContext = nil
            }
            outputs += try await summarizePiece(half, bookTitle: bookTitle, outputLanguage: outputLanguage, llm: llm, contextWindow: contextWindow, label: "\(label).\(index + 1)", depth: depth + 1, context: halfContext, onProgress: onProgress, onSpeed: onSpeed)
        }
        return outputs
    }

    private func aiChapters(from response: String, item: (parentTitle: String, piece: String), documentType: DocumentType, onProgress: (@Sendable (String) -> Void)?) -> [AIChapterResult] {
        let parentTitle = item.parentTitle
        let piece = item.piece
        let sections = Self.parseHeadedSections(response, fallbackTitle: parentTitle)
        if sections.isEmpty {
            // Overlong heading-less answers are split later by
            // `splitOversizedChapters` (configurable max length).
            onProgress?("    -> Keine Zwischenüberschriften — wird als 1 Kapitel übernommen.")
            return [AIChapterResult(title: parentTitle, sourceText: piece, summarizedText: response)]
        }
        let headingNames = sections.map(\.heading).joined(separator: " | ")
        onProgress?("    -> \(sections.count) Kapitel-Abschnitte erkannt: [\(headingNames.prefix(120))]")
        return sections.map { section in
            // Books keep their real chapter as the parent (`groupTitle`);
            // the AI heading is the fine-grained title. Packaging composes
            // "Gruppe — Titel" from both (plan 7.3). Other document types
            // have no meaningful parent — their batch's lead chapter title
            // is not a hierarchy level — so they stay flat.
            let groupTitle = documentType == .book ? parentTitle : nil
            return AIChapterResult(title: section.heading, groupTitle: groupTitle, sourceText: piece, summarizedText: section.text)
        }
    }

    /// Last ~`maxCharacters` of a chunk's SOURCE, cut to start at a sentence
    /// boundary if possible (falling back to a word boundary) — the
    /// continuity context for the next call (plan 7.4). Taken from the
    /// source, not from any answer, so every call can start immediately and
    /// in parallel.
    static func contextTail(of text: String, maxCharacters: Int = 600) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 0, trimmed.count > maxCharacters else { return trimmed }
        let tail = String(trimmed.suffix(maxCharacters))

        // Prefer starting right after the first sentence end inside the
        // tail; fall back to the first word boundary.
        if let sentenceEnd = tail.firstRange(of: ". ") ?? tail.firstRange(of: "! ") ?? tail.firstRange(of: "? ") {
            let candidate = String(tail[sentenceEnd.upperBound...])
            if !candidate.isEmpty { return candidate }
        }
        if let firstSpace = tail.firstIndex(of: " ") {
            let candidate = String(tail[tail.index(after: firstSpace)...])
            if !candidate.isEmpty { return candidate }
        }
        return tail
    }

    /// True when a chunk begins at a real topic boundary — a heading-like
    /// line (short, no sentence punctuation) that opens the piece. Continuity
    /// context is skipped there (plan 7.4): a fresh section needs no bridge.
    static func startsWithTopicBoundary(_ piece: String) -> Bool {
        guard let firstLine = piece.split(separator: "\n", omittingEmptySubsequences: true).first else { return false }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count <= 80 else { return false }
        let trailing = line.last ?? "."
        if ".!?;:,".contains(trailing) { return false }
        return line.first?.isLetter ?? false
            || (line.first?.isNumber == true && line.contains(where: \.isLetter))
    }

    /// Groups original chapters into batches for one summarization call
    /// each. Never splits a chapter's text between two batches — a batch is
    /// always a whole number of consecutive original chapters. For
    /// `.book`, every chapter gets its own solo batch (so its title survives
    /// as the top-level chapter name with no cross-chapter mixing); other
    /// types combine consecutive chapters up to a per-document evenly
    /// distributed target size.
    ///
    /// The target size is computed, not just capped at `budget`: it starts
    /// from the fewest calls that could possibly work (`totalChars / budget`,
    /// rounded down) and only adds another call if that would make the
    /// average call more than 15% over budget — e.g. a 400-character
    /// leftover after an otherwise-full batch gets folded into that batch
    /// instead of becoming its own near-empty call, while a genuinely long
    /// document gets evenly sized calls instead of a large first batch and a
    /// small trailing one. A single chapter bigger than the resulting target
    /// still gets its own solo batch (handled by the oversized-splitting
    /// logic in `summarizeIntoChapters`).
    static func buildBatches(chapters: [(title: String, text: String)], documentType: DocumentType, budget: Int, tolerance: Double = 0.15) -> [[Int]] {
        guard !chapters.isEmpty else { return [] }

        if documentType == .book {
            return chapters.indices.map { [$0] }
        }

        let lengths = chapters.map(\.text.count)
        let totalChars = lengths.reduce(0, +)
        guard totalChars > 0, budget > 0 else { return chapters.indices.map { [$0] } }

        var idealBatchCount = max(1, totalChars / budget)
        while Double(totalChars) / Double(idealBatchCount) > Double(budget) * (1 + tolerance) {
            idealBatchCount += 1
        }
        let cap = Int((Double(totalChars) / Double(idealBatchCount)) * (1 + tolerance))

        var batches: [[Int]] = []
        var current: [Int] = []
        var currentChars = 0

        for index in chapters.indices {
            let length = lengths[index]
            if length > cap {
                if !current.isEmpty {
                    batches.append(current)
                    current = []
                    currentChars = 0
                }
                batches.append([index])
                continue
            }
            if currentChars + length > cap, !current.isEmpty {
                batches.append(current)
                current = []
                currentChars = 0
            }
            current.append(index)
            currentChars += length
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// A section of a batch response, delimited by heading markers.
    struct HeadedSection: Sendable, Equatable {
        let heading: String
        let text: String
    }

    /// Splits a response on the highest / primary heading level present:
    /// 1. If `## ` (H2, standard) is present >= 1 times, splits on `## ` lines,
    ///    treating any `# ` at the top as document title/preamble and `### ` as internal subheadings.
    /// 2. If `## ` is absent but `# ` (H1) is present >= 2 times, splits on `# ` lines.
    /// 3. If neither is present but `### ` (H3) is present >= 2 times, splits on `### ` lines.
    /// 4. Fallback: bold standalone lines `**Heading**` or numbered lines `1. Heading`
    ///    if no hash-based markdown headings exist.
    ///
    /// This prevents over-fragmentation when the model writes sub-headings or document titles.
    static func parseHeadedSections(_ response: String, fallbackTitle: String = "Einleitung") -> [HeadedSection] {
        let pattern = selectDominantHeadingPattern(in: response)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }

        let nsResponse = response as NSString
        let matches = regex.matches(in: response, range: NSRange(location: 0, length: nsResponse.length))
        guard !matches.isEmpty else { return [] }

        var sections: [HeadedSection] = []

        // Preserve preamble text before the first heading if non-trivial
        if matches[0].range.location > 0 {
            let preamble = nsResponse.substring(with: NSRange(location: 0, length: matches[0].range.location))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if preamble.count > 40 {
                sections.append(HeadedSection(heading: fallbackTitle, text: preamble))
            }
        }

        for (matchIndex, match) in matches.enumerated() {
            let fullMatch = nsResponse.substring(with: match.range)
            let heading = sanitizeHeadingText(fullMatch)
            guard !heading.isEmpty else { continue }

            let contentStart = match.range.location + match.range.length
            let contentEnd = matchIndex + 1 < matches.count ? matches[matchIndex + 1].range.location : nsResponse.length
            guard contentEnd > contentStart else { continue }

            let content = nsResponse.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContent.isEmpty else { continue }

            sections.append(HeadedSection(heading: heading, text: trimmedContent))
        }

        return sections
    }

    private static func selectDominantHeadingPattern(in text: String) -> String {
        func countMatches(_ pattern: String) -> Int {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
            return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        }

        let h2Count = countMatches(#"(?m)^##[ \t]+[^\n#]+"#)
        if h2Count >= 1 {
            return #"(?m)^##[ \t]+([^\n#]+?)#*[ \t]*$"#
        }

        let h1Count = countMatches(#"(?m)^#[ \t]+[^\n#]+"#)
        if h1Count >= 2 {
            return #"(?m)^#[ \t]+([^\n#]+?)#*[ \t]*$"#
        }

        let h3Count = countMatches(#"(?m)^###[ \t]+[^\n#]+"#)
        if h3Count >= 2 {
            return #"(?m)^###[ \t]+([^\n#]+?)#*[ \t]*$"#
        }

        if h1Count == 1 {
            return #"(?m)^#[ \t]+([^\n#]+?)#*[ \t]*$"#
        }
        if h3Count == 1 {
            return #"(?m)^###[ \t]+([^\n#]+?)#*[ \t]*$"#
        }

        let boldCount = countMatches(#"(?m)^\*\*[^\n*]+\*\*[ \t]*$"#)
        if boldCount >= 2 {
            return #"(?m)^\*\*([^\n*]+?)\*\*[ \t]*$"#
        }

        let numberedCount = countMatches(#"(?m)^(?:Chapter|Kapitel|Section|Teil|\d{1,3}[\.\)])[ \t]+[^\n]+"#)
        if numberedCount >= 2 {
            return #"(?m)^(?:(?:Chapter|Kapitel|Section|Teil|\d{1,3}[\.\)])[ \t]+([^\n]+?))[ \t]*$"#
        }

        return #"(?m)^(?:(#{1,4})[ \t]+([^\n#]+?)#*|\*\*([^\n*]+?)\*\*|(?:(?:Chapter|Kapitel|Section|Teil|\d{1,3}[\.\)])[ \t]+([^\n]+?)))[ \t]*$"#
    }

    private static func sanitizeHeadingText(_ heading: String) -> String {
        var trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("#") || trimmed.hasPrefix("*") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        while trimmed.hasSuffix("#") || trimmed.hasSuffix("*") || trimmed.hasSuffix(":") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// Strips pre-existing runs of 2+ "#" characters from extracted source text
    /// before sending to the model, so OCR noise or markdown artifacts don't create false splits.
    static func sanitizeHeadingMarkers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "#{2,}") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Chunking

    /// Splits text into (at most) `count` parts of similar length, cutting
    /// only at paragraph boundaries — each cut at the boundary closest to
    /// its ideal position k·total/count.
    static func partition(_ text: String, into count: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        guard count > 1, paragraphs.count > 1 else { return [text] }
        var offsets: [Int] = [] // cumulative length after paragraph i
        var running = 0
        for paragraph in paragraphs {
            running += paragraph.count + 2
            offsets.append(running)
        }
        var cuts: [Int] = [] // paragraph index where a new part starts
        for k in 1..<count {
            let ideal = Double(running) * Double(k) / Double(count)
            let best = (0..<(paragraphs.count - 1)).min { abs(Double(offsets[$0]) - ideal) < abs(Double(offsets[$1]) - ideal) }! + 1
            if best > (cuts.last ?? 0) { cuts.append(best) }
        }
        var parts: [String] = []
        var start = 0
        for cut in cuts + [paragraphs.count] {
            parts.append(paragraphs[start..<cut].joined(separator: "\n\n"))
            start = cut
        }
        return parts.filter { !$0.isEmpty }
    }

    /// Splits text into exactly two parts at the paragraph boundary closest
    /// to the middle (falls back to a sentence/word boundary for a single
    /// giant paragraph).
    static func halve(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        if paragraphs.count > 1 {
            let total = text.count
            var running = 0
            var bestIndex = 1
            var bestDistance = Int.max
            for index in 1..<paragraphs.count {
                running += paragraphs[index - 1].count + 2
                let distance = abs(running - total / 2)
                if distance < bestDistance { bestDistance = distance; bestIndex = index }
            }
            return [paragraphs[..<bestIndex].joined(separator: "\n\n"), paragraphs[bestIndex...].joined(separator: "\n\n")]
        }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let cut = text[middle...].firstIndex(where: { $0 == "." || $0 == " " }).map { text.index(after: $0) } ?? middle
        return [String(text[..<cut]), String(text[cut...])].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func chunk(text: String, maxCharacters: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        for paragraph in paragraphs {
            if paragraph.count > maxCharacters {
                flush()
                var remaining = Substring(paragraph)
                while !remaining.isEmpty {
                    let end = remaining.index(remaining.startIndex, offsetBy: maxCharacters, limitedBy: remaining.endIndex) ?? remaining.endIndex
                    chunks.append(String(remaining[remaining.startIndex..<end]))
                    remaining = remaining[end...]
                }
                continue
            }
            if current.count + paragraph.count + 2 > maxCharacters {
                flush()
            }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        flush()

        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Networking

    private func fillTemplate(_ template: String, text: String, bookTitle: String) -> String {
        template
            .replacingOccurrences(of: "{{text}}", with: text)
            .replacingOccurrences(of: "{{title}}", with: bookTitle.isEmpty ? "Unbekannt" : bookTitle)
            // {{chapter_title}} no longer maps to anything (a batch can span
            // several original chapters) — blank it out rather than leaving
            // the literal placeholder in prompts saved before this change.
            .replacingOccurrences(of: "{{chapter_title}}", with: "")
    }
}
