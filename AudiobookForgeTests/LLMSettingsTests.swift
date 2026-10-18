import Foundation
import XCTest
@testable import AudiobookForge

final class LLMSettingsTests: XCTestCase {
    func testExistingSettingsDecodeAndKeepLMStudioValues() throws {
        let data = Data(#"{"llmBaseURL":"http://localhost:1234/v1","llmModel":"existing-model","llmProvider":"lmStudio"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.llmProvider, .lmStudio)
        XCTAssertEqual(settings.activeLLMBaseURL, "http://localhost:1234/v1")
        XCTAssertEqual(settings.activeLLMModel, "existing-model")
    }

    func testFreshSettingsDefaultToOMLX() {
        XCTAssertEqual(AppSettings().llmProvider, .omlx)
        XCTAssertEqual(AppSettings().activeLLMBaseURL, LLMProviderID.omlx.defaultBaseURL)
    }

    /// Values saved by the intermediate (always-sent) sampling design must
    /// not turn into overrides — otherwise they'd keep masking the model preset.
    func testLegacySamplingKeysAreIgnored() throws {
        let data = Data(#"{"llmTemperature":0.9,"llmTopP":1.0,"llmTopK":40,"llmProvider":"omlx","omlxModel":"m"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.omlxGeneration.temperature, 0.4, "legacy 0.9 ignored, app default applies")
        XCTAssertNil(settings.omlxGeneration.topP)
        XCTAssertNil(settings.omlxGeneration.topK)
        XCTAssertEqual(settings.activeLLMModel, "m")
    }

    func testUnsetOptionsAreNotSentSoServerPresetApplies() {
        var settings = AppSettings()
        settings.omlxModel = "any-future-model"
        XCTAssertEqual(settings.omlxGeneration.temperature, 0.4, "app default override")
        settings.omlxGeneration.temperature = nil
        let body = LLMClient(settings: settings).requestBody(messages: [], model: "any-future-model", purpose: .summary, inputCharacters: 30_000, contextWindow: nil)
        for key in ["temperature", "top_p", "top_k", "min_p", "presence_penalty", "repetition_penalty", "seed"] {
            XCTAssertNil(body[key], "\(key) should not be sent when not overridden")
        }
        // Default: thinking off via the generic template switch, no budget.
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertNil(body["thinking_budget"])
        // Automatic output allowance: 30k chars ≈ 10k tokens → 60% = 6000.
        XCTAssertEqual(body["max_tokens"] as? Int, 6000)
    }

    func testOverridesAndThinkingAreSent() {
        var settings = AppSettings()
        settings.omlxGeneration.temperature = 0.35
        settings.omlxGeneration.topK = 20
        settings.omlxGeneration.presencePenalty = 0
        settings.omlxGeneration.thinkingMode = .on
        settings.omlxGeneration.thinkingBudgetTokens = 200 // clamped to minimum
        settings.omlxGeneration.reasoningEffort = "low"
        let body = LLMClient(settings: settings).requestBody(messages: [], model: "m", purpose: .summary, inputCharacters: 3_000, contextWindow: nil)
        XCTAssertEqual(body["temperature"] as? Double, 0.35)
        XCTAssertEqual(body["top_k"] as? Int, 20)
        XCTAssertEqual(body["presence_penalty"] as? Double, 0)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
        XCTAssertEqual(body["thinking_budget"] as? Int, LLMGenerationOptions.minimumThinkingBudget)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual(body["max_tokens"] as? Int, 2048 + LLMGenerationOptions.minimumThinkingBudget)
    }

    func testModelDefaultThinkingSendsNoSwitch() {
        var settings = AppSettings()
        settings.omlxGeneration.thinkingMode = .modelDefault
        settings.omlxGeneration.thinkingBudgetTokens = 0
        let body = LLMClient(settings: settings).requestBody(messages: [], model: "m", purpose: .summary, inputCharacters: 3_000, contextWindow: nil)
        XCTAssertNil(body["chat_template_kwargs"])
        XCTAssertNil(body["thinking_budget"])
    }

    func testVisionUsesItsOwnThinkingMode() {
        var settings = AppSettings()
        settings.omlxGeneration.thinkingMode = .on
        settings.llmVisionThinkingMode = .off
        let body = LLMClient(settings: settings).requestBody(messages: [], model: "m", purpose: .vision, inputCharacters: 100, contextWindow: nil)
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
    }

    func testThinkingBudgetIsOMLXOnly() {
        var settings = AppSettings()
        settings.llmProvider = .lmStudio
        settings.lmStudioGeneration.thinkingMode = .on
        let body = LLMClient(settings: settings).requestBody(messages: [], model: "m", purpose: .summary, inputCharacters: 100, contextWindow: nil)
        XCTAssertNil(body["thinking_budget"])
        XCTAssertNotNil(body["chat_template_kwargs"])
    }

    func testAutomaticMaxTokensRespectsContextWindow() {
        var options = LLMGenerationOptions()
        options.thinkingMode = .off
        let tokens = LLMClient.automaticMaxTokens(inputCharacters: 60_000, options: options, contextWindow: 24_000)
        // input ≈ 20 000 tokens; room = 24 000 - 20 000 - 1024 = 2976
        XCTAssertEqual(tokens, 2976)
    }

    func testContextWindowCapsSummarizationBudget() {
        var settings = AppSettings()
        settings.paperTuning.summarizationChunkCharacterBudget = 75_000
        XCTAssertEqual(settings.effectiveSummarizationBudget(for: .paper, contextWindow: nil), 75_000)
        XCTAssertEqual(settings.effectiveSummarizationBudget(for: .paper, contextWindow: 262_144), 75_000)
        // 16k window, thinking off: (16384-1536)/1.6 = 9280 tokens → 27 840 chars
        XCTAssertEqual(settings.effectiveSummarizationBudget(for: .paper, contextWindow: 16_384), 27_840)
        settings.llmContextLimitTokens = 16_384
        XCTAssertEqual(settings.effectiveSummarizationBudget(for: .paper, contextWindow: 262_144), 27_840)
    }

    func testStripReasoning() {
        XCTAssertEqual(LLMClient.stripReasoning("<think>\nplan\n</think>\n\n## A\nText"), "## A\nText")
        XCTAssertEqual(LLMClient.stripReasoning("leftover reasoning</think>\n## A\nText"), "## A\nText")
        XCTAssertEqual(LLMClient.stripReasoning("## A\nText<think>unterminated"), "## A\nText")
        XCTAssertEqual(LLMClient.stripReasoning("Plain"), "Plain")
    }

    func testParseCompletionReadsUsageAndFinishReason() throws {
        let json = #"{"choices":[{"message":{"content":"Hallo","reasoning_content":"x"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":20,"completion_tokens_details":{"reasoning_tokens":5}}}"#
        let completion = try LLMClient.parseCompletion(Data(json.utf8), duration: 2)
        XCTAssertEqual(completion.content, "Hallo")
        XCTAssertTrue(completion.wasTruncated)
        XCTAssertEqual(completion.reasoningTokens, 5)
        XCTAssertEqual(completion.tokensPerSecond, 10)
    }

    func testOMLXPresetParsingFlagsImplausibleTopP() throws {
        let json = #"{"version":1,"models":{"Qwen3.6-35B-A3B-UD-MLX-4bit":{"max_context_window":156000,"max_tokens":10000,"temperature":0.7,"top_p":95.0,"top_k":20,"presence_penalty":1.0,"thinking_budget_enabled":false}}}"#
        let preset = try XCTUnwrap(LLMServerPreset.parseOMLXModelSettings(Data(json.utf8), modelID: "qwen3.6-35b-a3b-ud-mlx-4bit"))
        XCTAssertEqual(preset.temperature, 0.7)
        XCTAssertEqual(preset.topK, 20)
        XCTAssertEqual(preset.maxContextWindow, 156_000)
        XCTAssertEqual(preset.warnings.count, 1)
    }

    func testPreferredModelMatchesLMStudioIDAndSkipsNonChatModels() {
        let ids = ["OmniVoice-bf16", "Qwen3-Embedding-4B-MLX-8bit", "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit", "Qwen3.5-2B-bf16", "Qwen3.6-35B-A3B-6bit", "Qwen3.6-35B-A3B-UD-MLX-4bit"]
        XCTAssertEqual(LLMClient.preferredModel(from: ids, hint: "qwen3.6-35b-a3b-ud-mlx"), "Qwen3.6-35B-A3B-UD-MLX-4bit")
        XCTAssertEqual(LLMClient.preferredModel(from: ids, hint: ""), "Qwen3.5-2B-bf16")
        XCTAssertNil(LLMClient.preferredModel(from: ["OmniVoice-bf16"], hint: ""))
    }

    func testImplausibleTopPPresetIsCorrectedOnlyWhenNotOverridden() {
        var settings = AppSettings()
        settings.omlxModel = "m"
        var preset = LLMServerPreset()
        preset.topP = 95
        var body = LLMClient(settings: settings, serverPreset: preset).requestBody(messages: [], model: "m", purpose: .summary, inputCharacters: 100, contextWindow: nil)
        XCTAssertEqual(body["top_p"] as? Double, 0.95)

        settings.correctImplausibleServerPresets = false
        body = LLMClient(settings: settings, serverPreset: preset).requestBody(messages: [], model: "m", purpose: .summary, inputCharacters: 100, contextWindow: nil)
        XCTAssertNil(body["top_p"])

        settings.correctImplausibleServerPresets = true
        settings.omlxGeneration.topP = 0.8
        body = LLMClient(settings: settings, serverPreset: preset).requestBody(messages: [], model: "m", purpose: .summary, inputCharacters: 100, contextWindow: nil)
        XCTAssertEqual(body["top_p"] as? Double, 0.8)

        preset.topP = 0.95
        settings.omlxGeneration.topP = nil
        body = LLMClient(settings: settings, serverPreset: preset).requestBody(messages: [], model: "m", purpose: .summary, inputCharacters: 100, contextWindow: nil)
        XCTAssertNil(body["top_p"], "plausible presets are left to the server")
    }

    func testOldDefaultPromptIsUpgradedButCustomPromptKept() throws {
        for legacy in PromptTemplates.legacyDefaultSystemPrompts {
            let data = try JSONSerialization.data(withJSONObject: ["promptTemplates": ["systemPrompt": legacy]])
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).promptTemplates.systemPrompt, PromptTemplates.defaultSystemPrompt)
        }
        let custom = try JSONSerialization.data(withJSONObject: ["promptTemplates": ["systemPrompt": "Mein eigener Prompt"]])
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: custom).promptTemplates.systemPrompt, "Mein eigener Prompt")
    }

    func testDefaultPromptAsksForListenerFriendlyOutput() {
        let prompt = PromptTemplates.defaultSystemPrompt
        XCTAssertTrue(prompt.contains("Write all numbers as words"))
        XCTAssertTrue(prompt.contains("Expand abbreviations"))
        XCTAssertTrue(prompt.contains("citation markers"))
        XCTAssertTrue(prompt.contains("\n- Write all numbers"), "list items must stay on their own lines")
    }

    func testOMLXPortIsReadFromItsSettingsFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("omlx-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"server":{"host":"127.0.0.1","port":8072},"model":{}}"#.utf8).write(to: file)
        XCTAssertEqual(OMLXLocalConfig.serverBaseURL(settingsFile: file), "http://127.0.0.1:8072/v1")
        try Data(#"{"server":{"host":"0.0.0.0","port":9000}}"#.utf8).write(to: file)
        XCTAssertEqual(OMLXLocalConfig.serverBaseURL(settingsFile: file), "http://127.0.0.1:9000/v1")
        XCTAssertNil(OMLXLocalConfig.serverBaseURL(settingsFile: file.appendingPathExtension("missing")))
    }

    func testOMLXLifecycleSettingsDefaultsAndDecoding() throws {
        let defaults = AppSettings()
        XCTAssertFalse(defaults.autoStartOMLX, "autoStartOMLX must default to false")
        XCTAssertFalse(defaults.autoUnloadOMLXAfterPass, "autoUnloadOMLXAfterPass must default to false")

        let jsonWithoutKeys = Data(#"{"llmProvider":"omlx"}"#.utf8)
        let decoded1 = try JSONDecoder().decode(AppSettings.self, from: jsonWithoutKeys)
        XCTAssertFalse(decoded1.autoStartOMLX)
        XCTAssertFalse(decoded1.autoUnloadOMLXAfterPass)

        let jsonWithKeys = Data(#"{"autoStartOMLX":true,"autoUnloadOMLXAfterPass":true}"#.utf8)
        let decoded2 = try JSONDecoder().decode(AppSettings.self, from: jsonWithKeys)
        XCTAssertTrue(decoded2.autoStartOMLX)
        XCTAssertTrue(decoded2.autoUnloadOMLXAfterPass)
    }

    func testOMLXCLIResolution() {
        // If oMLX is installed on the machine, cliURL should find it; otherwise nil
        let isCLI = OMLXLifecycleManager.isCLIAvailable
        if isCLI {
            XCTAssertNotNil(OMLXLifecycleManager.cliURL)
        } else {
            XCTAssertNil(OMLXLifecycleManager.cliURL)
        }
    }
}
