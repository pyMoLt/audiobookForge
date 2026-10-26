import Foundation

/// Manages the Piper TTS side-car environment: a small Python venv with
/// `piper-tts` installed, plus a folder of downloaded voice models (.onnx +
/// .onnx.json). Separate from the Kokoro bridge because Piper is a plain
/// native CLI once installed — no custom bridge script needed.
final class PiperEnvironmentManager: @unchecked Sendable {
    static let shared = PiperEnvironmentManager()

    let directory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = appSupport.appendingPathComponent("AudiobookForge/bridge_piper", isDirectory: true)
    }

    var piperExecutableURL: URL {
        directory.appendingPathComponent(".venv/bin/piper")
    }

    var voicesDirectory: URL {
        let url = directory.appendingPathComponent("voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var setupScriptURL: URL {
        directory.appendingPathComponent("setup_piper_env.sh")
    }

    func isEnvironmentReady() -> Bool {
        FileManager.default.isExecutableFile(atPath: piperExecutableURL.path)
    }

    /// Multi-speaker voices carry their style after "#" (v4.2), e.g.
    /// "de_DE-thorsten_emotional-medium#whisper"; all styles share one model.
    static func baseVoiceID(_ voiceID: String) -> String {
        String(voiceID.split(separator: "#", maxSplits: 1).first ?? Substring(voiceID))
    }

    static func style(of voiceID: String) -> String? {
        let parts = voiceID.split(separator: "#", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    /// Speaker id of a style, from the model's `speaker_id_map`.
    func speakerID(for voiceID: String) -> Int? {
        guard let style = Self.style(of: voiceID), let data = try? Data(contentsOf: onnxConfigURL(for: voiceID)) else { return nil }
        return Self.speakerID(style: style, config: data)
    }

    static func speakerID(style: String, config: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let map = json["speaker_id_map"] as? [String: Any] else { return nil }
        return (map[style] as? Int) ?? (map[style] as? NSNumber)?.intValue
    }

    func isVoiceDownloaded(_ voiceID: String) -> Bool {
        FileManager.default.fileExists(atPath: onnxURL(for: voiceID).path)
            && FileManager.default.fileExists(atPath: onnxConfigURL(for: voiceID).path)
    }

    func onnxURL(for voiceID: String) -> URL {
        voicesDirectory.appendingPathComponent("\(Self.baseVoiceID(voiceID)).onnx")
    }

    func onnxConfigURL(for voiceID: String) -> URL {
        voicesDirectory.appendingPathComponent("\(Self.baseVoiceID(voiceID)).onnx.json")
    }

    func ensureResourcesCopied() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bundledSetup = Bundle.main.url(forResource: "setup_piper_env", withExtension: "sh", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "setup_piper_env", withExtension: "sh")
        else {
            throw BridgeEnvironmentError.resourcesMissing
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: setupScriptURL.path) {
            try fm.removeItem(at: setupScriptURL)
        }
        try fm.copyItem(at: bundledSetup, to: setupScriptURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setupScriptURL.path)
    }

    func runSetup(onOutput: @escaping @Sendable (String) -> Void) async throws {
        try ensureResourcesCopied()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [setupScriptURL.path, directory.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                text.split(separator: "\n", omittingEmptySubsequences: true).forEach { onOutput(String($0)) }
            }
            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BridgeEnvironmentError.setupFailed(exitCode: proc.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Downloads one voice's .onnx + .onnx.json from the public
    /// `rhasspy/piper-voices` model repository on Hugging Face.
    func downloadVoice(_ voice: PiperVoice, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(from: voice.onnxURL, to: onnxURL(for: voice.id)) { progress in onProgress(progress * 0.95) }
        try await download(from: voice.configURL, to: onnxConfigURL(for: voice.id)) { _ in onProgress(1.0) }
    }

    /// A stalled connection gives up after 30 s instead of hanging for
    /// minutes (v4.2); a download is tried up to three times.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: configuration)
    }()

    private func download(from remoteURL: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var lastError: Error = BridgeEnvironmentError.setupFailed(exitCode: -1)
        for attempt in 1...3 {
            do {
                let (tempURL, response) = try await Self.session.download(from: remoteURL, delegate: DownloadProgress(onProgress))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw BridgeEnvironmentError.setupFailed(exitCode: -1)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                onProgress(1.0)
                return
            } catch {
                lastError = error
                if Task.isCancelled || attempt == 3 { break }
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
        throw lastError
    }
}

/// Reports a download's progress (the async API has no progress of its own).
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

struct PiperVoice: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let languageCode: String

    var onnxURL: URL { URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/\(hfPath).onnx")! }
    var configURL: URL { URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/\(hfPath).onnx.json")! }

    /// e.g. "de/de_DE/thorsten/medium/de_DE-thorsten-medium"
    private var hfPath: String {
        let parts = id.split(separator: "-")
        let localeAndSpeaker = String(parts[0]) // de_DE
        let speaker = parts.count > 1 ? String(parts[1]) : ""
        let quality = parts.count > 2 ? String(parts[2]) : "medium"
        let lang = String(localeAndSpeaker.prefix(2))
        return "\(lang)/\(localeAndSpeaker)/\(speaker)/\(quality)/\(id)"
    }
}

enum PiperVoiceCatalog {
    static let allVoices: [PiperVoice] = [
        PiperVoice(id: "de_DE-thorsten-medium", displayName: "Thorsten (DE, mittel)", languageCode: "de"),
        PiperVoice(id: "de_DE-thorsten-high", displayName: "Thorsten (DE, hoch)", languageCode: "de"),
        PiperVoice(id: "de_DE-thorsten_emotional-medium", displayName: "Thorsten Emotional (DE, mittel)", languageCode: "de"),
        PiperVoice(id: "de_DE-eva_k-x_low", displayName: "Eva K. (DE, sehr niedrig)", languageCode: "de"),
        PiperVoice(id: "de_DE-karlsson-low", displayName: "Karlsson (DE, niedrig)", languageCode: "de"),
        PiperVoice(id: "de_DE-kerstin-low", displayName: "Kerstin (DE, niedrig)", languageCode: "de"),
        PiperVoice(id: "de_DE-mls-medium", displayName: "MLS (DE, mittel)", languageCode: "de"),
        PiperVoice(id: "de_DE-pavoque-low", displayName: "Pavoque (DE, niedrig)", languageCode: "de"),
        PiperVoice(id: "de_DE-ramona-low", displayName: "Ramona (DE, niedrig)", languageCode: "de"),
        PiperVoice(id: "en_US-lessac-medium", displayName: "Lessac (US-Englisch, mittel)", languageCode: "en"),
        PiperVoice(id: "en_US-ryan-high", displayName: "Ryan (US-Englisch, hoch)", languageCode: "en"),
        PiperVoice(id: "en_GB-alba-medium", displayName: "Alba (GB-Englisch, mittel)", languageCode: "en"),
    ]

    static func voice(id: String) -> PiperVoice? {
        let base = PiperEnvironmentManager.baseVoiceID(id)
        return allVoices.first { $0.id == base }
    }
}
