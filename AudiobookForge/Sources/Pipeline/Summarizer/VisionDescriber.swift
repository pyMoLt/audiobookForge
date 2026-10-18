import Foundation

/// Describes a single embedded figure/chart/table image via the same
/// OpenAI-compatible endpoint used for summarization, using the standard
/// multimodal message format (an `image_url` content part with a base64
/// data URI). Requires a vision-capable model to actually be loaded at that
/// endpoint — if it isn't, the call fails and the image is simply skipped
/// (this whole pass is opt-in and best-effort, never a hard requirement).
enum VisionDescriber {
    static func describe(jpegData: Data, prompt: String, settings: AppSettings) async throws -> String {
        let dataURI = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"

        let promptText = prompt

        let content: [[String: Any]] = [
            ["type": "text", "text": promptText],
            ["type": "image_url", "image_url": ["url": dataURI]],
        ]
        // Thinking for image captions follows its own setting (default off):
        // a short description gains little from reasoning but costs seconds
        // per figure.
        let completion = try await LLMClient(settings: settings).complete(
            system: nil,
            user: content,
            purpose: .vision,
            inputCharacters: 4000,
            contextWindow: nil,
            model: settings.llmVisionModelOverride.isEmpty ? settings.activeLLMModel : settings.llmVisionModelOverride,
            timeout: settings.llmVisionTimeoutSeconds
        )
        return completion.content
    }
}
