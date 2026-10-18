import Foundation

/// Whether the model should reason ("think") before answering. Sent via the
/// generic `chat_template_kwargs.enable_thinking` switch that oMLX forwards
/// to every model's chat template, so it keeps working for future models
/// without any model-specific code here. `.modelDefault` sends nothing and
/// leaves the decision to the server's per-model preset.
enum LLMThinkingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case modelDefault
    case on
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modelDefault: return "Modell-Standard"
        case .on: return "An"
        case .off: return "Aus"
        }
    }
}

/// Per-provider generation parameters. Every sampling field is optional on
/// purpose: `nil` means "don't send it", which makes oMLX (and LM Studio)
/// apply the preset configured for whichever model is loaded. That keeps
/// models swappable — the app never bakes in values tuned for one model —
/// while still letting the user override any single parameter.
struct LLMGenerationOptions: Codable, Sendable, Equatable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var presencePenalty: Double?
    var repetitionPenalty: Double?
    var seed: Int?
    /// nil = automatic (sized from the input length and thinking budget,
    /// see `LLMClient.automaticMaxTokens`), not the server default — a
    /// server preset like oMLX's `max_tokens: 10000` would otherwise
    /// silently truncate the summary of a long batch.
    var maxOutputTokens: Int?
    var thinkingMode: LLMThinkingMode = .off
    /// Upper bound for reasoning tokens when thinking is on. 0 = unlimited.
    /// Kept >= `LLMGenerationOptions.minimumThinkingBudget`: verified against
    /// oMLX 0.7.0 that a tiny budget makes the model continue its reasoning
    /// inside the visible answer, which would end up being narrated.
    var thinkingBudgetTokens: Int = 4096
    /// Optional OpenAI-style reasoning depth ("low", "medium", "high", …) for
    /// models whose template understands it. Empty = not sent.
    var reasoningEffort: String = ""

    static let minimumThinkingBudget = 1024

    init() {}

    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, minP, presencePenalty, repetitionPenalty, seed
        case maxOutputTokens, thinkingMode, thinkingBudgetTokens, reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMGenerationOptions()
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        topK = try c.decodeIfPresent(Int.self, forKey: .topK)
        minP = try c.decodeIfPresent(Double.self, forKey: .minP)
        presencePenalty = try c.decodeIfPresent(Double.self, forKey: .presencePenalty)
        repetitionPenalty = try c.decodeIfPresent(Double.self, forKey: .repetitionPenalty)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        thinkingMode = try c.decodeIfPresent(LLMThinkingMode.self, forKey: .thinkingMode) ?? d.thinkingMode
        thinkingBudgetTokens = try c.decodeIfPresent(Int.self, forKey: .thinkingBudgetTokens) ?? d.thinkingBudgetTokens
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? d.reasoningEffort
    }

    var effectiveThinkingBudget: Int? {
        guard thinkingMode != .off, thinkingBudgetTokens > 0 else { return nil }
        return max(thinkingBudgetTokens, Self.minimumThinkingBudget)
    }
}

/// Model presets as configured on the server side (currently: oMLX's
/// `model_settings.json`). Shown next to each setting so "Modell-Standard"
/// is not a black box, and copyable into overrides.
struct LLMServerPreset: Sendable, Equatable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var presencePenalty: Double?
    var repetitionPenalty: Double?
    var maxTokens: Int?
    var maxContextWindow: Int?
    var enableThinking: Bool?
    var thinkingBudgetTokens: Int?

    /// Values that look like configuration mistakes (e.g. `top_p: 95`).
    var warnings: [String] {
        var result: [String] = []
        if let topP, !(0...1).contains(topP) { result.append("Top P \(topP) liegt außerhalb von 0…1 (gemeint ist vermutlich \(topP / 100)).") }
        if let temperature, temperature < 0 || temperature > 2 { result.append("Temperatur \(temperature) ist unplausibel.") }
        if let minP, !(0...1).contains(minP) { result.append("Min P \(minP) liegt außerhalb von 0…1.") }
        return result
    }

    /// Reads `<oMLX base path>/model_settings.json`. The base path follows
    /// oMLX's own bootstrap file, falling back to `~/.omlx`.
    static func readOMLXPreset(modelID: String) -> LLMServerPreset? {
        let fileManager = FileManager.default
        let url = OMLXLocalConfig.basePath.appendingPathComponent("model_settings.json")
        guard fileManager.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return nil }
        return parseOMLXModelSettings(data, modelID: modelID)
    }

    static func parseOMLXModelSettings(_ data: Data, modelID: String) -> LLMServerPreset? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any] else { return nil }
        let entry = (models[modelID] as? [String: Any])
            ?? models.first(where: { $0.key.caseInsensitiveCompare(modelID) == .orderedSame })?.value as? [String: Any]
        guard let entry else { return nil }

        func double(_ key: String) -> Double? { (entry[key] as? NSNumber)?.doubleValue }
        func int(_ key: String) -> Int? { (entry[key] as? NSNumber)?.intValue }

        var preset = LLMServerPreset()
        preset.temperature = double("temperature")
        preset.topP = double("top_p")
        preset.topK = int("top_k")
        preset.minP = double("min_p")
        preset.presencePenalty = double("presence_penalty")
        preset.repetitionPenalty = double("repetition_penalty")
        if let maxTokens = int("max_tokens"), maxTokens > 0 { preset.maxTokens = maxTokens }
        preset.maxContextWindow = int("max_context_window")
        preset.enableThinking = entry["enable_thinking"] as? Bool
        if (entry["thinking_budget_enabled"] as? Bool) == true { preset.thinkingBudgetTokens = int("thinking_budget_tokens") }
        return preset
    }
}

struct LLMModelInfo: Sendable, Equatable, Hashable {
    let id: String
    /// Context window the server reports (oMLX: `max_model_len`, LM Studio:
    /// not part of /v1/models). nil = unknown.
    let contextWindow: Int?
}

struct LLMCompletion: Sendable {
    let content: String
    let finishReason: String?
    let promptTokens: Int?
    let completionTokens: Int?
    let reasoningTokens: Int?
    let durationSeconds: Double

    var wasTruncated: Bool { finishReason == "length" }

    var tokensPerSecond: Double? {
        guard let completionTokens, durationSeconds > 0 else { return nil }
        return Double(completionTokens) / durationSeconds
    }
}

enum LLMPurpose: Sendable {
    case summary
    case vision
}

/// The one place that talks to an OpenAI-compatible chat endpoint. Builds
/// the request body from the active provider's `LLMGenerationOptions` and
/// cleans up the response (reasoning stripped, usage parsed).
struct LLMClient: Sendable {
    let settings: AppSettings
    /// oMLX preset of the active model (read once per client), used only to
    /// correct obviously broken values. See `correctImplausibleServerPresets`.
    let serverPreset: LLMServerPreset?

    init(settings: AppSettings) {
        self.init(settings: settings, serverPreset: settings.llmProvider == .omlx ? LLMServerPreset.readOMLXPreset(modelID: settings.activeLLMModel) : nil)
    }

    init(settings: AppSettings, serverPreset: LLMServerPreset?) {
        self.settings = settings
        self.serverPreset = serverPreset
    }

    var options: LLMGenerationOptions { settings.activeGenerationOptions }

    // MARK: Models

    func listModels() async throws -> [LLMModelInfo] {
        guard let url = endpoint("models") else { throw SummarizerError.badResponse("Ungültige Basis-URL") }
        var request = URLRequest(url: url, timeoutInterval: max(1, settings.llmConnectionTimeoutSeconds))
        applyAuth(&request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SummarizerError.endpointUnreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SummarizerError.badResponse("HTTP-Status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        struct ModelsResponse: Decodable {
            struct Model: Decodable { let id: String; let max_model_len: Int? }
            let data: [Model]
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { LLMModelInfo(id: $0.id, contextWindow: $0.max_model_len) }
    }

    /// Context window of the active model: manual setting first, then what
    /// the server reports, then the oMLX preset file.
    func activeContextWindow() async -> Int? {
        if settings.llmContextLimitTokens > 0 { return settings.llmContextLimitTokens }
        if let models = try? await listModels(),
           let match = models.first(where: { $0.id == settings.activeLLMModel }),
           let window = match.contextWindow {
            return window
        }
        if settings.llmProvider == .omlx {
            return LLMServerPreset.readOMLXPreset(modelID: settings.activeLLMModel)?.maxContextWindow
        }
        return nil
    }

    // MARK: Model choice

    /// Picks a sensible chat model when none is configured: first a model
    /// whose normalized ID starts with the hint (e.g. the LM Studio ID
    /// "qwen3.6-35b-a3b-ud-mlx" matches oMLX's "Qwen3.6-35B-A3B-UD-MLX-4bit"),
    /// otherwise the first model that isn't obviously a speech, embedding,
    /// reranker or tokenizer model. Name-based only, so it keeps working
    /// for models the app has never heard of.
    static func preferredModel(from ids: [String], hint: String) -> String? {
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let hintKey = normalized(hint)
        if !hintKey.isEmpty, let match = ids.first(where: { normalized($0).hasPrefix(hintKey) || hintKey.hasPrefix(normalized($0)) }) {
            return match
        }
        let nonChatMarkers = ["tts", "embed", "rerank", "tokenizer", "omnivoice", "voxcpm", "chatterbox", "whisper", "kokoro", "parakeet", "markitdown"]
        return ids.first { id in
            let lower = id.lowercased()
            return !nonChatMarkers.contains { lower.contains($0) }
        }
    }

    // MARK: Request building

    /// Rough, deliberately conservative token estimate (≈3 characters per
    /// token covers German and English prose; real tokenizers usually do
    /// slightly better, so this errs on the side of larger reservations).
    static func estimatedTokens(forCharacters characters: Int) -> Int {
        max(1, characters / 3)
    }

    /// Output allowance when no explicit max is configured: a dense
    /// summary of N input tokens rarely needs more than ~60% of N, plus the
    /// thinking budget (or a generous reserve if thinking is unbounded),
    /// clamped to what fits in the context window.
    static func automaticMaxTokens(inputCharacters: Int, options: LLMGenerationOptions, contextWindow: Int?) -> Int {
        let inputTokens = estimatedTokens(forCharacters: inputCharacters)
        var allowance = max(2048, Int(Double(inputTokens) * 0.6))
        if options.thinkingMode != .off {
            allowance += options.effectiveThinkingBudget ?? 16384
        }
        if let contextWindow, contextWindow > 0 {
            let room = contextWindow - inputTokens - 1024
            if room > 1024 { allowance = min(allowance, room) }
        }
        return allowance
    }

    func requestBody(messages: [[String: Any]], model: String, purpose: LLMPurpose, inputCharacters: Int, contextWindow: Int?) -> [String: Any] {
        var opts = options
        if purpose == .vision { opts.thinkingMode = settings.llmVisionThinkingMode }

        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if let v = opts.temperature { body["temperature"] = v }
        if let v = opts.topP {
            body["top_p"] = v
        } else if settings.correctImplausibleServerPresets, settings.llmProvider == .omlx,
                  let presetTopP = serverPreset?.topP, presetTopP > 1, presetTopP <= 100 {
            // e.g. a preset of `top_p: 95` (meant 0.95) would otherwise
            // effectively disable nucleus sampling.
            body["top_p"] = presetTopP / 100
        }
        if let v = opts.topK { body["top_k"] = v }
        if let v = opts.minP { body["min_p"] = v }
        if let v = opts.presencePenalty { body["presence_penalty"] = v }
        if let v = opts.repetitionPenalty { body["repetition_penalty"] = v }
        if let v = opts.seed { body["seed"] = v }
        body["max_tokens"] = opts.maxOutputTokens
            ?? Self.automaticMaxTokens(inputCharacters: inputCharacters, options: opts, contextWindow: contextWindow)

        switch opts.thinkingMode {
        case .modelDefault:
            break
        case .on, .off:
            body["chat_template_kwargs"] = ["enable_thinking": opts.thinkingMode == .on]
        }
        if opts.thinkingMode != .off {
            if settings.llmProvider == .omlx, let budget = opts.effectiveThinkingBudget {
                body["thinking_budget"] = budget
            }
            let effort = opts.reasoningEffort.trimmingCharacters(in: .whitespaces)
            if !effort.isEmpty { body["reasoning_effort"] = effort }
        }
        return body
    }

    // MARK: Calling

    func complete(system: String?, user: Any, purpose: LLMPurpose, inputCharacters: Int, contextWindow: Int?, model: String? = nil, timeout: Double? = nil) async throws -> LLMCompletion {
        guard let url = endpoint("chat/completions") else { throw SummarizerError.badResponse("Ungültige Basis-URL") }
        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])

        var request = URLRequest(url: url, timeoutInterval: max(5, timeout ?? settings.llmRequestTimeoutSeconds))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        let body = requestBody(messages: messages, model: model ?? settings.activeLLMModel, purpose: purpose, inputCharacters: inputCharacters, contextWindow: contextWindow)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SummarizerError.endpointUnreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SummarizerError.badResponse("HTTP \(statusCode): \(bodyText.prefix(300))")
        }
        return try Self.parseCompletion(data, duration: Date().timeIntervalSince(started))
    }

    static func parseCompletion(_ data: Data, duration: Double) throws -> LLMCompletion {
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            struct Usage: Decodable {
                struct Details: Decodable { let reasoning_tokens: Int? }
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let completion_tokens_details: Details?
            }
            let choices: [Choice]
            let usage: Usage?
        }
        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw SummarizerError.badResponse("Antwort nicht lesbar: \(error.localizedDescription)")
        }
        guard let choice = decoded.choices.first else { throw SummarizerError.emptyCompletion }
        let content = stripReasoning(choice.message.content ?? "")
        guard !content.isEmpty else { throw SummarizerError.emptyCompletion }
        return LLMCompletion(
            content: content,
            finishReason: choice.finish_reason,
            promptTokens: decoded.usage?.prompt_tokens,
            completionTokens: decoded.usage?.completion_tokens,
            reasoningTokens: decoded.usage?.completion_tokens_details?.reasoning_tokens,
            durationSeconds: duration
        )
    }

    /// Servers normally move reasoning into `reasoning_content`, but a model
    /// without a configured reasoning parser emits it inline. Removes
    /// complete `<think>…</think>` blocks, an unterminated leading block
    /// (truncated reasoning), and everything before a stray `</think>`
    /// (template opened the tag in the prompt).
    static func stripReasoning(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"<think>[\s\S]*?</think>"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let closing = result.range(of: "</think>") {
            result = String(result[closing.upperBound...])
        }
        if let opening = result.range(of: "<think>") {
            result = String(result[..<opening.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private func endpoint(_ path: String) -> URL? {
        URL(string: settings.activeLLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)
    }

    private func applyAuth(_ request: inout URLRequest) {
        if !settings.activeLLMAPIKey.isEmpty {
            request.setValue("Bearer \(settings.activeLLMAPIKey)", forHTTPHeaderField: "Authorization")
        }
    }
}


/// Where the local oMLX server keeps its configuration, and which address
/// it listens on. oMLX's server reads `<base>/settings.json`; the base path
/// comes from the menubar app's bootstrap file or `config.json`, defaulting
/// to `~/.omlx`. Reading the port from there means the app follows a port
/// change in oMLX (e.g. 8072) instead of assuming 8000.
enum OMLXLocalConfig {
    static var basePath: URL {
        let home = NSHomeDirectory()
        let support = home + "/Library/Application Support/oMLX"
        if let raw = try? String(contentsOfFile: support + "/base-path", encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return URL(fileURLWithPath: trimmed) }
        }
        if let data = FileManager.default.contents(atPath: support + "/config.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base = json["base_path"] as? String, !base.isEmpty {
            return URL(fileURLWithPath: base)
        }
        return URL(fileURLWithPath: home + "/.omlx")
    }

    /// `http://<host>:<port>/v1` from oMLX's settings.json, nil if unreadable.
    static func serverBaseURL(settingsFile: URL = basePath.appendingPathComponent("settings.json")) -> String? {
        guard let data = FileManager.default.contents(atPath: settingsFile.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = json["server"] as? [String: Any],
              let port = (server["port"] as? NSNumber)?.intValue else { return nil }
        var host = (server["host"] as? String) ?? "127.0.0.1"
        if host == "0.0.0.0" || host.isEmpty { host = "127.0.0.1" }
        return "http://\(host):\(port)/v1"
    }
}
