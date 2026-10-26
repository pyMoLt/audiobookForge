import Foundation
import AVFoundation

/// Streams raw 16-bit PCM through ffmpeg — optional clean-up and loudness
/// normalization plus the final codec encode — so chapter audio never
/// exists as a large uncompressed WAV on disk. PCM is fed straight into
/// ffmpeg's stdin.
///
/// v4.4: calm normalization needs the chapter's loudness before it can set
/// one fixed gain, so the stream first lands in a small lossless FLAC next
/// to the chapter (~2.8 MB per minute, deleted right after), is measured,
/// and then encoded once. Dynamic normalization and no normalization stay
/// a single pass.
///
/// Two feeding modes:
/// - Swift forwards PCM chunks itself (`write(_:)`, used by PiperEngine).
/// - A producer subprocess writes PCM directly: its `standardOutput` is set
///   to `pcmPipe`, so the bytes flow kernel-side without Swift in the loop
///   (used by the Python bridges via KokoroEngine/SupertonicEngine).
///
/// Declared `@unchecked Sendable`: all mutable state sits behind `LockedBox`,
/// and the wrapped `Process`/`Pipe` are only driven from the owning
/// engine's cancellation/termination flow.
final class ChapterAudioEncoder: @unchecked Sendable {
    enum EncoderError: LocalizedError {
        case unsupportedOutput(String)
        case ffmpegFailed(String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .unsupportedOutput(let ext): return "Nicht unterstütztes Kapitel-Audioformat: .\(ext)"
            case .ffmpegFailed(let message): return "ffmpeg-Kodierung fehlgeschlagen: \(message)"
            case .noAudio: return "Es wurden keine PCM-Daten an den Kodierer übergeben."
            }
        }
    }

    /// File extension of the per-chapter audio file for a book's output
    /// format. M4B/M4A books keep AAC chapters (.m4a), MP3 books keep MP3
    /// chapters (.mp3) — so packaging is a pure remux with no re-encode.
    static func fileExtension(for format: OutputFormat) -> String {
        switch format {
        case .m4b, .m4a: return "m4a"
        case .mp3Chapters: return "mp3"
        }
    }

    /// Builds the ffmpeg argument list for one streaming encode pass.
    /// `sampleRate` is the producer's rate (e.g. 24000 for Kokoro, 22050
    /// for Piper); the encode keeps it as-is, mono.
    static func arguments(
        sampleRate: Int,
        outputURL: URL,
        settings: AppSettings,
        inputSpecifier: String = "pipe:0"
    ) throws -> [String] {
        var arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "s16le", "-ar", String(max(1, sampleRate)), "-ac", "1",
            "-i", inputSpecifier,
        ]
        let filters = AudioPolish.streamingFilters(settings)
        if !filters.isEmpty {
            arguments += ["-af", filters.joined(separator: ",")]
        }
        if AudioPolish.usesCalmPass(settings) {
            // Validate the extension now, not after the whole chapter streamed.
            _ = try AudioPolish.codecArguments(for: outputURL, settings: settings)
            arguments += ["-c:a", "flac", stageURL(for: outputURL).path]
        } else {
            arguments += try AudioPolish.codecArguments(for: outputURL, settings: settings)
        }
        return arguments
    }

    /// The lossless stage file of the calm pass, next to the chapter.
    static func stageURL(for outputURL: URL) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension("stage.flac")
    }

    /// Second half of the calm pass: measure the stage, encode it once with
    /// a fixed gain and the peak limiter, delete the stage.
    static func encodeCalm(stage: URL, outputURL: URL, settings: AppSettings) async throws {
        guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settings) else { throw PackagerError.ffmpegNotFound }
        defer { try? FileManager.default.removeItem(at: stage) }
        let loudness = try await AudioPolish.measureLoudness(of: stage, ffmpeg: ffmpeg)
        let gain = AudioPolish.calmGain(measuredLUFS: loudness.integratedLUFS, targetLUFS: settings.loudnessTargetLUFS)
        let arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", stage.path,
                         "-af", AudioPolish.calmFilter(gainDB: gain, truePeakDB: settings.loudnessTruePeakDB)]
            + (try AudioPolish.codecArguments(for: outputURL, settings: settings))
        try await FFmpegRunner.run(executable: ffmpeg, arguments: arguments)
    }

    private let process: Process
    private let stdinPipe: Pipe
    private let outputURL: URL
    private let settings: AppSettings
    private let state = LockedBox<EncoderState>(EncoderState())

    private struct EncoderState {
        var continuation: CheckedContinuation<Void, Error>?
        var errorLines: [String] = []
        var terminated = false
        var exitStatus: Int32?
    }

    /// The pipe ffmpeg reads PCM from. Producers that stream themselves
    /// (Python bridges) set their `standardOutput` to this.
    var pcmPipe: Pipe { stdinPipe }

    /// Write end for engines whose PCM Swift forwards.
    var pcmWriter: FileHandle { stdinPipe.fileHandleForWriting }

    /// Starts ffmpeg for one streaming encode. `stdinPipe` is the pipe
    /// ffmpeg reads PCM from — callers create it up front so a producer
    /// subprocess (Python bridge) can be wired to it before the sample
    /// rate is even known; ffmpeg only starts once the rate arrived.
    static func start(sampleRate: Int, outputURL: URL, settings: AppSettings, stdinPipe: Pipe) throws -> ChapterAudioEncoder {
        try ChapterAudioEncoder(sampleRate: sampleRate, outputURL: outputURL, settings: settings, stdinPipe: stdinPipe)
    }

    private init(sampleRate: Int, outputURL: URL, settings: AppSettings, stdinPipe: Pipe) throws {
        guard let ffmpeg = FFmpegLocator.resolve(settings: settings) else {
            throw PackagerError.ffmpegNotFound
        }
        self.outputURL = outputURL
        self.settings = settings
        self.process = Process()
        self.process.executableURL = ffmpeg
        self.process.arguments = try Self.arguments(sampleRate: sampleRate, outputURL: outputURL, settings: settings)
        self.stdinPipe = stdinPipe
        self.process.standardInput = stdinPipe
        self.process.standardOutput = Pipe()

        let errorPipe = Pipe()
        self.process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { [state] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            state.withLock { current in
                current.errorLines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
                if current.errorLines.count > 20 { current.errorLines.removeFirst(current.errorLines.count - 20) }
            }
        }

        process.terminationHandler = { [state] proc in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            state.withLock { current in
                current.terminated = true
                current.exitStatus = proc.terminationStatus
                current.continuation?.resume(returning: ())
                current.continuation = nil
            }
        }

        try process.run()
    }

    /// Forwards PCM produced by a subprocess Swift controls (Piper). Safe
    /// to call from a pipe's readability handler (blocks with backpressure
    /// if ffmpeg is slower than the producer).
    func write(_ data: Data) throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { return }
        // Throwing Swift API: the ObjC `write(_:)` raises an ObjC
        // exception on a broken pipe (dead ffmpeg child), which nothing
        // catches and which killed the whole process.
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Closes the PCM input and waits for ffmpeg to finalize the file.
    /// Returns the encoded duration in seconds. Throws if ffmpeg failed or
    /// no PCM was ever written.
    func finish() async throws -> Double {
        stdinPipe.fileHandleForWriting.closeFile()
        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyTerminated = state.withLock { current -> Bool in
                    if current.terminated { return true }
                    current.continuation = continuation
                    return false
                }
                if alreadyTerminated { continuation.resume() }
            }
        } onCancel: {
            abort()
        }

        let (status, lines) = state.withLock { ($0.exitStatus, $0.errorLines) }
        let stage = Self.stageURL(for: outputURL)
        guard status == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: stage)
            throw EncoderError.ffmpegFailed(lines.joined(separator: "\n"))
        }
        if AudioPolish.usesCalmPass(settings) {
            guard let size = try? FileManager.default.attributesOfItem(atPath: stage.path)[.size] as? Int, size > 1000 else {
                try? FileManager.default.removeItem(at: stage)
                throw EncoderError.noAudio
            }
            do {
                try await Self.encodeCalm(stage: stage, outputURL: outputURL, settings: settings)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int, size > 1000 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw EncoderError.noAudio
        }
        return try await WaveFileInspector.durationSeconds(url: outputURL)
    }

    /// Kills ffmpeg and removes the partial output file (cancellation or
    /// producer failure). No-op if the encode already finished cleanly.
    func abort() {
        let alreadyTerminated = state.withLock { $0.terminated }
        if !alreadyTerminated, process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: Self.stageURL(for: outputURL))
    }
}
