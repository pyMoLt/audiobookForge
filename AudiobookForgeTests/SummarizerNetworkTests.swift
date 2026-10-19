import Foundation
import XCTest
@testable import AudiobookForge

/// Fake OpenAI-compatible server: answers each chat request from a handler
/// that sees the user prompt, so tests can exercise truncation retries and
/// concurrent ordering without a real model.
final class StubLLMProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((String) -> (content: String, finishReason: String, delay: TimeInterval))?
    nonisolated(unsafe) static var requestBodies: [[String: Any]] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.llm" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Connection checks hit GET …/models; answer with a valid models
        // list so pipeline-level tests can pass the connection gate.
        if request.httpMethod == "GET", request.url?.path.hasSuffix("models") == true {
            let payload: [String: Any] = ["data": [["id": "stub-model", "max_model_len": 8192]]]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            DispatchQueue.global().async {
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 65536)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            bodyData = data
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData ?? Data())) as? [String: Any] ?? [:]
        Self.lock.withLock { Self.requestBodies.append(body) }
        let messages = body["messages"] as? [[String: Any]] ?? []
        let user = messages.last?["content"] as? String ?? ""
        let reply = Self.handler?(user) ?? (content: "", finishReason: "stop", delay: 0)
        let payload: [String: Any] = [
            "choices": [["message": ["content": reply.content], "finish_reason": reply.finishReason]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 10],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class SummarizerNetworkTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(StubLLMProtocol.self)
        StubLLMProtocol.requestBodies = []
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubLLMProtocol.self)
        StubLLMProtocol.handler = nil
    }

    private func settings(parallel: Int) -> AppSettings {
        var settings = AppSettings()
        settings.llmProvider = .omlx
        settings.omlxBaseURL = "http://stub.llm/v1"
        settings.omlxModel = "stub-model"
        settings.omlxParallelRequests = parallel
        // These tests exercise networking/retry/ordering — chapter merging
        // has its own dedicated tests (AIChapterMergerTests).
        settings.minAIChapterCharacters = 0
        return settings
    }

    private func paragraphs(_ marker: String, count: Int) -> String {
        (0..<count).map { "\(marker) paragraph \($0) " + String(repeating: "x", count: 300) }.joined(separator: "\n\n")
    }

    func testTruncatedAnswerIsSplitAndRetriedInsteadOfAccepted() async throws {
        let text = paragraphs("Alpha", count: 30) // ~9.5k chars
        StubLLMProtocol.handler = { prompt in
            // Full-size piece "runs out of tokens"; halves fit.
            prompt.count > 8000 ? ("## Cut\nTruncated…", "length", 0) : ("## Half\nComplete half summary.", "stop", 0)
        }
        let client = SummarizerClient(settings: settings(parallel: 1))
        let result = try await client.summarizeIntoChapters(bookTitle: "T", chapters: [(title: "Kap", text: text)], documentType: .paper, characterBudget: 50_000)
        XCTAssertEqual(StubLLMProtocol.requestBodies.count, 3, "1 truncated call + 2 halves")
        XCTAssertEqual(result.map(\.summarizedText), ["Complete half summary.", "Complete half summary."])
        XCTAssertFalse(result.contains { $0.summarizedText.contains("Truncated") })
    }

    func testParallelCallsKeepDocumentOrder() async throws {
        let chapters = (0..<4).map { index in (title: "Kapitel \(index)", text: paragraphs("Chapter\(index)", count: 3)) }
        StubLLMProtocol.handler = { prompt in
            let index = (0..<4).first { prompt.contains("Chapter\($0) paragraph") } ?? -1
            // Earlier chapters answer *later*, so completion order is reversed.
            return ("## Teil \(index)\nInhalt \(index).", "stop", Double(4 - index) * 0.15)
        }
        let progressCount = LockedBox(0)
        let client = SummarizerClient(settings: settings(parallel: 4))
        let result = try await client.summarizeIntoChapters(
            bookTitle: "T", chapters: chapters, documentType: .book, characterBudget: 50_000,
            onStructuredProgress: { _ in progressCount.withLock { $0 += 1 } }
        )
        XCTAssertEqual(result.map(\.summarizedText), ["Inhalt 0.", "Inhalt 1.", "Inhalt 2.", "Inhalt 3."])
        XCTAssertEqual(result.first?.title, "Teil 0")
        XCTAssertEqual(result.first?.groupTitle, "Kapitel 0")
        XCTAssertEqual(progressCount.withLock { $0 }, 5, "initial + one per call")
    }

    func testReasoningInContentIsNotNarrated() async throws {
        StubLLMProtocol.handler = { _ in ("<think>I should summarize.</think>\n## Ergebnis\nSauberer Text.", "stop", 0) }
        let client = SummarizerClient(settings: settings(parallel: 1))
        let result = try await client.summarizeIntoChapters(bookTitle: "T", chapters: [(title: "K", text: "Quelle.")], documentType: .paper, characterBudget: 50_000)
        XCTAssertEqual(result.map(\.summarizedText), ["Sauberer Text."])
    }
}
