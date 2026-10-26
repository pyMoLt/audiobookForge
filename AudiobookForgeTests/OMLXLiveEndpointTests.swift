import XCTest
import Foundation
@testable import AudiobookForge

final class OMLXLiveEndpointTests: XCTestCase {
    override func setUpWithError() throws {
        try LiveTestGate.require("oMLX-Live-Test")
    }

    private func makeSettings() -> AppSettings {
        var settings = AppSettings()
        settings.llmProvider = .omlx
        settings.omlxBaseURL = "http://127.0.0.1:8000/v1"
        settings.omlxAPIKey = "admin"
        settings.omlxModel = "Qwen3.6-35B-A3B-oQ4e-mtp"
        settings.aiChapterContinuityEnabled = true
        settings.minAIChapterCharacters = 0
        settings.aiChapterMaxCharacters = 0
        return settings
    }

    func testLiveOMLXConnectionAndModelListing() async throws {
        let settings = makeSettings()
        let client = SummarizerClient(settings: settings)
        let result = await client.testConnection()

        switch result {
        case .success(let modelIDs):
            print(">>> Live oMLX Models discovered: \(modelIDs)")
            XCTAssertFalse(modelIDs.isEmpty, "oMLX should return at least one loaded model")
            XCTAssertTrue(
                modelIDs.contains(where: { $0.contains("Qwen") || $0.contains("Nemotron") || $0.contains("gemma") }),
                "Expected one of the loaded models to be in the model list"
            )
        case .failure(let error):
            XCTFail("oMLX connection test failed: \(error.localizedDescription)")
        }
    }

    func testLiveOMLXSummarizeSnippetWithHeadingsAndContinuity() async throws {
        var settings = makeSettings()
        // If the preferred 35B model isn't the only one, ensure we use whatever Qwen model is active or available
        let client = SummarizerClient(settings: settings)
        let modelsResult = await client.testConnection()
        guard case .success(let models) = modelsResult, !models.isEmpty else {
            XCTFail("Live oMLX server not responding")
            return
        }

        if let matchingModel = models.first(where: { $0.contains("Qwen3.6-35B") }) ?? models.first(where: { $0.contains("Qwen") }) ?? models.first {
            settings.omlxModel = matchingModel
        }

        let testContent = """
        Ebenezer Scrooge was a tight-fisted hand at the grindstone, Scrooge! a squeezing, wrenching, grasping, scraping, clutching, covetous, old sinner! Hard and sharp as flint, from which no steel had ever struck out generous fire; secret, and self-contained, and solitary as an oyster. The cold within him froze his old features, nipped his pointed nose, shrivelled his cheek, stiffened his gait; made his eyes red, his thin lips blue; and spoke out shrewdly in his grating voice. A frosty rime was on his head, and on his eyebrows, and his wiry chin. He carried his own low temperature always about with him; he iced his office in the dog-days; and didn't thaw it one degree at Christmas.

        External heat and cold had little influence on Scrooge. No warmth could warm, no wintry weather chill him. No wind that blew was bitterer than he, no falling snow was more intent upon its purpose, no pelting rain less open to entreaty. Foul weather didn't know where to have him. The heaviest rain, and snow, and hail, and sleet, could boast of the advantage over him in only one respect. They often 'came down' handsomely, and Scrooge never did.
        """

        let liveClient = SummarizerClient(settings: settings)
        let results = try await liveClient.summarizeIntoChapters(
            bookTitle: "A Christmas Carol Test",
            chapters: [(title: "Marley's Ghost Intro", text: testContent)],
            documentType: .book,
            characterBudget: 2000
        )

        print(">>> Live oMLX Summarization produced \(results.count) chapters:")
        for (i, r) in results.enumerated() {
            print("[\(i)] Title: \"\(r.title)\", groupTitle: \"\(r.groupTitle ?? "-")\"")
            print("    Summary (\(r.summarizedText.count) chars): \(r.summarizedText.prefix(120))...")
        }

        XCTAssertFalse(results.isEmpty, "Summarization must yield at least one chapter result")
        XCTAssertFalse(results[0].summarizedText.isEmpty, "Summarized text must not be empty")
        XCTAssertEqual(results[0].sourceText, testContent, "Source text must be preserved for diff display")
    }
}
