import Foundation
import XCTest
@testable import AudiobookForge

/// Plan 7.4 — continuity context between chunked summarization calls,
/// exercised against the stub LLM endpoint.
final class SummarizerContinuityTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(StubLLMProtocol.self)
        StubLLMProtocol.requestBodies = []
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubLLMProtocol.self)
        StubLLMProtocol.handler = nil
    }

    private func settings(parallel: Int = 1, continuity: Bool = true) -> AppSettings {
        var settings = AppSettings()
        settings.llmProvider = .omlx
        settings.omlxBaseURL = "http://stub.llm/v1"
        settings.omlxModel = "stub-model"
        settings.omlxParallelRequests = parallel
        settings.aiChapterContinuityEnabled = continuity
        settings.minAIChapterCharacters = 0
        settings.aiChapterMaxCharacters = 0
        return settings
    }

    /// Paragraph with a marker and enough text that two paragraphs exceed
    /// the small budget used in these tests (~440 characters each).
    private func paragraph(_ marker: String, sentences: Int = 8) -> String {
        (0..<sentences).map { "\(marker) Satz \($0) mit etwas Länge zum Auffüllen des Textes." }.joined(separator: " ")
    }

    private func userPrompt(at index: Int) -> String {
        let lock = StubLLMProtocol.lock
        return lock.withLock {
            let body = StubLLMProtocol.requestBodies[index]
            let messages = body["messages"] as? [[String: Any]] ?? []
            return messages.last?["content"] as? String ?? ""
        }
    }

    private func promptCount() -> Int {
        StubLLMProtocol.lock.withLock { StubLLMProtocol.requestBodies.count }
    }

    // (a) The 2nd chunk's prompt carries a context block with the tail of
    //     the 1st chunk's SOURCE, cut at a sentence boundary.
    func testSecondChunkCarriesContextTailOfFirstChunkSource() async throws {
        let piece1 = [paragraph("Alpha"), paragraph("Beta")].joined(separator: "\n\n")
        let piece2 = paragraph("Gamma")
        let text = [piece1, piece2].joined(separator: "\n\n")
        StubLLMProtocol.handler = { _ in ("## Teil\nInhalt.", "stop", 0) }
        let client = SummarizerClient(settings: settings())
        _ = try await client.summarizeIntoChapters(bookTitle: "T", chapters: [(title: "Kap", text: text)], documentType: .paper, characterBudget: 1000)
        XCTAssertEqual(promptCount(), 2, "Ein Batch, zwei Stücke")
        let first = userPrompt(at: 0)
        let second = userPrompt(at: 1)

        XCTAssertFalse(first.contains(ResponsePostprocess.contextMarker), "(b) Erstes Stück ohne Kontext")
        XCTAssertTrue(second.contains(ResponsePostprocess.contextMarker))
        // The context is the tail of the source (marker sentences near the
        // end of piece 1), not the beginning.
        XCTAssertTrue(second.contains("Beta Satz 5"), "Kontext enthält das Ende der Quelle des 1. Stücks")
        XCTAssertFalse(second.contains("Alpha Satz 0"), "Kontext ist der Schwanz, nicht der Anfang")
        // Cut at a sentence boundary: the block starts with a full sentence.
        let context = second.components(separatedBy: ResponsePostprocess.contextMarker)[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(context.hasPrefix("Beta Satz") || context.contains(". "), "Satzgrenze statt mitten im Wort")
    }

    // (c) A chunk that begins at a real topic boundary (heading-like line)
    //     gets no context. Budget 880 forces the chunk split right before
    //     the heading paragraph, so the heading opens the second piece.
    func testThemeBoundaryChunkGetsNoContext() async throws {
        let piece1 = [paragraph("Alpha"), paragraph("Beta")].joined(separator: "\n\n")
        let piece2 = "Zweite Überschrift\n\n" + paragraph("Gamma")
        let text = [piece1, piece2].joined(separator: "\n\n")
        StubLLMProtocol.handler = { _ in ("## Teil\nInhalt.", "stop", 0) }
        let client = SummarizerClient(settings: settings())
        _ = try await client.summarizeIntoChapters(bookTitle: "T", chapters: [(title: "Kap", text: text)], documentType: .paper, characterBudget: 880)
        XCTAssertEqual(promptCount(), 2)
        let second = userPrompt(at: 1)
        XCTAssertTrue(second.contains("Zweite Überschrift"), "Zweites Stück beginnt mit der Überschrift")
        XCTAssertFalse(second.contains(ResponsePostprocess.contextMarker), "Themengrenze braucht keine Brücke")
    }

    // (d) Parallel runs keep the document order even with contexts.
    func testParallelRunWithContextKeepsOrder() async throws {
        let chapters = (0..<2).map { index in
            (title: "Kapitel \(index)", text: [paragraph("Ch\(index)Alpha"), paragraph("Ch\(index)Beta"), paragraph("Ch\(index)Gamma")].joined(separator: "\n\n"))
        }
        StubLLMProtocol.handler = { prompt in
            let delay = prompt.contains("Ch0") ? 0.2 : 0.0 // later pieces finish first
            return ("## Teil\nInhalt.", "stop", delay)
        }
        let client = SummarizerClient(settings: settings(parallel: 4))
        let result = try await client.summarizeIntoChapters(bookTitle: "T", chapters: chapters, documentType: .book, characterBudget: 1000)
        XCTAssertEqual(promptCount(), 4, "Zwei Kapitel à zwei Stücke (Alpha+Beta, Gamma)")
        XCTAssertEqual(result.map(\.summarizedText), Array(repeating: "Inhalt.", count: 4))
        XCTAssertEqual(result.map(\.groupTitle), ["Kapitel 0", "Kapitel 0", "Kapitel 1", "Kapitel 1"])
        // The 2nd piece of each chapter carries context from its 1st; the
        // 1st pieces don't. Identify by content marker.
        var withContext = 0
        for index in 0..<promptCount() {
            if userPrompt(at: index).contains(ResponsePostprocess.contextMarker) { withContext += 1 }
        }
        XCTAssertEqual(withContext, 2, "Je Kapitel: erstes Stück ohne, zweites mit Kontext")
    }

    // (e) If the model echoes the context block, the parser removes it from
    //     the narrated result.
    func testEchoedContextIsRemovedFromResult() async throws {
        let piece1 = [paragraph("Alpha"), paragraph("Beta")].joined(separator: "\n\n")
        let piece2 = paragraph("Gamma")
        let text = [piece1, piece2].joined(separator: "\n\n")
        StubLLMProtocol.handler = { prompt in
            guard prompt.contains(ResponsePostprocess.contextMarker) else {
                return ("## Anfang\nErster Abschnitt.", "stop", 0)
            }
            // Echo: marker line plus a verbatim sentence from the context.
            let context = prompt.components(separatedBy: ResponsePostprocess.contextMarker)[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let echoSentence = context.components(separatedBy: ".")[0]
            return ("## Fortsetzung\n\(ResponsePostprocess.contextMarker)\n\(echoSentence). Neuer Inhalt des zweiten Stücks.", "stop", 0)
        }
        let client = SummarizerClient(settings: settings())
        let result = try await client.summarizeIntoChapters(bookTitle: "T", chapters: [(title: "Kap", text: text)], documentType: .paper, characterBudget: 1000)
        XCTAssertEqual(result.count, 2)
        let continuation = result[1].summarizedText
        XCTAssertFalse(continuation.contains(ResponsePostprocess.contextMarker))
        XCTAssertFalse(continuation.contains("zum Auffüllen des Textes"), "Echo des Kontexts wird entfernt")
        XCTAssertTrue(continuation.contains("Neuer Inhalt des zweiten Stücks."))
    }

    // Continuity disabled restores the old behavior exactly: no context
    // anywhere.
    func testContinuityOffSendsNoContext() async throws {
        let text = [paragraph("Alpha"), paragraph("Beta"), paragraph("Gamma")].joined(separator: "\n\n")
        StubLLMProtocol.handler = { _ in ("## Teil\nInhalt.", "stop", 0) }
        let client = SummarizerClient(settings: settings(continuity: false))
        _ = try await client.summarizeIntoChapters(bookTitle: "T", chapters: [(title: "Kap", text: text)], documentType: .paper, characterBudget: 1000)
        XCTAssertGreaterThanOrEqual(promptCount(), 2)
        for index in 0..<promptCount() {
            XCTAssertFalse(userPrompt(at: index).contains(ResponsePostprocess.contextMarker))
        }
    }

    // Unit checks for the two pure helpers.
    func testContextTailCutsAtSentenceBoundary() {
        let text = "Erster Satz steht hier. Zweiter Satz folgt auf dem Fuß. Dritter Satz schließt ab. Vierter Satz zum Schluss."
        let tail = SummarizerClient.contextTail(of: text, maxCharacters: 40)
        XCTAssertTrue(tail.hasPrefix("Zweiter") || tail.hasPrefix("Dritter") || tail.hasPrefix("Vierter"), "Beginnt am Satzanfang: \(tail)")
        XCTAssertLessThanOrEqual(tail.count, 40)
    }

    func testStartsWithTopicBoundary() {
        XCTAssertTrue(SummarizerClient.startsWithTopicBoundary("2.3 Therapieoptionen\n\nDer Text beginnt."))
        XCTAssertTrue(SummarizerClient.startsWithTopicBoundary("Kurze Überschrift\n\nInhalt folgt."))
        XCTAssertFalse(SummarizerClient.startsWithTopicBoundary("Der Patient stellt sich mit Schmerzen vor. Weitere Einzelheiten."))
        XCTAssertFalse(SummarizerClient.startsWithTopicBoundary("Dies ist ein sehr langer Absatzanfang, der deutlich mehr als achtzig Zeichen umfasst und deshalb keine Überschrift sein kann."))
    }
}
