import Foundation
import PhononTTS

/// Phonon on the Neural Engine (v4.1): the Core ML bundle of a language,
/// loaded once per language in this process through Gradium's Swift
/// package. Used in the "Stromsparend" energy mode — not faster than the
/// CPU runtime (43× vs 56× real time measured), but it leaves the CPU free
/// and draws far less power. An instance speaks one utterance at a time,
/// so the actor serializes callers.
actor PhononNeuralEngine {
    static let shared = PhononNeuralEngine()

    private var loaded: [String: Phonon] = [:]

    static func phononLanguage(_ code: String) -> Language {
        switch code {
        case "de": return .german
        case "fr": return .french
        case "es": return .spanish
        case "pt": return .portuguese
        default: return .english
        }
    }

    private func instance(language: String, directory: URL) async throws -> Phonon {
        // Keyed by folder: English has two models (40m, 31m).
        if let existing = loaded[directory.path] { return existing }
        let phonon = try await Phonon.load(models: directory, language: Self.phononLanguage(language), computeUnit: .neuralEngine)
        loaded[directory.path] = phonon
        return phonon
    }

    /// Drops the loaded models (memory pressure, model removed).
    func unloadAll() { loaded.removeAll() }

    /// Speaks every planned segment: 24 kHz mono float samples per segment.
    func synthesize(segments: [String], voice: String, language: String, directory: URL,
                    onSegment: @Sendable (Int, [Float]) throws -> Void) async throws {
        let phonon = try await instance(language: language, directory: directory)
        let wanted = voice.precomposedStringWithCanonicalMapping.lowercased()
        if let match = phonon.voices.first(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == wanted }),
           phonon.voice != match {
            try await phonon.setVoice(match)
        }
        for (index, text) in segments.enumerated() {
            try Task.checkCancellation()
            let samples = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : try await phonon.synthesize(text)
            try onSegment(index, samples)
        }
    }
}
