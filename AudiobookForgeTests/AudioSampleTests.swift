import AVFoundation
import Foundation
import XCTest
@testable import AudiobookForge

/// Per-engine audio checks on one shared text, plus labeled listening
/// samples and a measurement table. Opt-in (synthesizes ~10 samples):
///   TEST_RUNNER_ABF_AUDIO_SAMPLES=<output dir> xcodebuild test -only-testing:AudiobookForgeTests/AudioSampleTests
/// Without the variable the samples go to a temp dir and the test still
/// verifies every installed engine.
final class AudioSampleTests: XCTestCase {
    /// Contains a deliberately hard-wrapped sentence (the mid-sentence pause
    /// regression), numbers, a date, an abbreviation, umlauts and ß.
    static let germanText = """
    Am 3. Oktober 2026 las Dr. Martina Schulz im Rathaus aus ihrem neuen Buch vor. Rund 250 Gäste hörten zu, als sie von der
    Brücke über die Isar erzählte, die zwischen 1899 und 1901 erbaut wurde und bis heute täglich von etwa 40.000 Menschen
    überquert wird. Danach diskutierte das Publikum über Klimaschutz, Mobilität und die Frage, wie Städte im Jahr 2050 aussehen könnten. Zum Schluss bedankte sich die Autorin herzlich und signierte noch fast zwei Stunden lang Bücher, während draußen die Straßenbahn vorbeifuhr.
    """

    static let englishText = """
    On the third of October, Doctor Martina Schulz read from her new book at the town hall. About 250 guests listened as she described the
    bridge across the river, built between 1899 and 1901 and still crossed by roughly forty thousand people every day. Afterwards the audience discussed climate policy, mobility, and what cities might look like in 2050.
    """

    struct Case {
        let engine: TTSEngineID
        let voice: String
        let label: String
        let english: Bool
        var configure: (inout AppSettings) -> Void = { _ in }
    }

    struct Measurement: Codable {
        let label: String
        let engine: String
        let voice: String
        let audioSeconds: Double
        let synthesisSeconds: Double
        let realTimeFactor: Double
        let charactersPerSecond: Double
        let rmsDB: Double
        let longestInternalPause: Double
        let segments: Int
        let file: String
    }

    func testEveryInstalledEngineProducesCleanSpeech() async throws {
        let outputDirectory: URL
        if let path = ProcessInfo.processInfo.environment["ABF_AUDIO_SAMPLES"], !path.isEmpty {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("abf-audio-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let cases: [Case] = [
            Case(engine: .kokoro, voice: "af_heart", label: "kokoro-en-af_heart", english: true),
            Case(engine: .kokoroGerman, voice: "martin", label: "kokoro-de-martin", english: false),
            Case(engine: .kokoroGerman, voice: "victoria", label: "kokoro-de-victoria", english: false),
            Case(engine: .kokoroThorsten, voice: "thorsten", label: "kokoro-thorsten", english: false),
            Case(engine: .piper, voice: "de_DE-thorsten-medium", label: "piper-thorsten-medium", english: false),
            Case(engine: .supertonic3, voice: "M1", label: "supertonic3-M1-steps8", english: false) { $0.supertonicSteps = 8 },
            Case(engine: .supertonic3, voice: "M1", label: "supertonic3-M1-steps4", english: false) { $0.supertonicSteps = 4 },
            Case(engine: .supertonic3, voice: "F1", label: "supertonic3-F1-steps8", english: false) { $0.supertonicSteps = 8 },
        ]

        var measurements: [Measurement] = []
        var skipped: [String] = []
        for testCase in cases {
            var settings = AppSettings()
            testCase.configure(&settings)
            let engine = TTSEngineFactory.engine(for: testCase.engine, settings: settings)
            guard await engine.isReady(voice: testCase.voice) else {
                skipped.append(testCase.label)
                continue
            }
            let text = testCase.english ? Self.englishText : Self.germanText
            let output = outputDirectory.appendingPathComponent("\(testCase.label).m4a")
            try? FileManager.default.removeItem(at: output)

            // Warm-up isn't separated on purpose: the pipeline also pays the
            // model load per chapter, so this is the realistic per-call cost.
            let started = Date()
            let segmentCount = LockedBox(0)
            let result = try await engine.synthesize(text: text, voice: testCase.voice, speed: 1.0, outputURL: output) { event in
                if case .segmentDone = event { segmentCount.withLock { $0 += 1 } }
            }
            let elapsed = Date().timeIntervalSince(started)

            let analysis = try Self.analyze(output)
            let pauses = try await Self.internalPauses(output)
            let longest = pauses.max() ?? 0
            let normalizedChars = Double(SentenceSplitter.split(text).joined(separator: " ").count)

            XCTAssertGreaterThan(analysis.duration, 8, "\(testCase.label): audio too short")
            XCTAssertEqual(analysis.duration, result.durationSeconds, accuracy: 1.0, "\(testCase.label): reported vs. file duration")
            XCTAssertGreaterThan(analysis.rmsDB, -35, "\(testCase.label): (near) silent output")
            let cps = normalizedChars / analysis.duration
            XCTAssertTrue((8...30).contains(cps), "\(testCase.label): implausible speech rate \(cps) chars/s")
            XCTAssertLessThan(longest, 1.5, "\(testCase.label): pause of \(longest) s inside the text")

            measurements.append(Measurement(
                label: testCase.label, engine: testCase.engine.rawValue, voice: testCase.voice,
                audioSeconds: analysis.duration, synthesisSeconds: elapsed, realTimeFactor: elapsed / analysis.duration,
                charactersPerSecond: cps, rmsDB: analysis.rmsDB, longestInternalPause: longest,
                segments: segmentCount.withLock { $0 }, file: output.lastPathComponent
            ))
        }

        XCTAssertFalse(measurements.isEmpty, "no engine was ready")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(measurements).write(to: outputDirectory.appendingPathComponent("measurements.json"))

        var table = "| Probe | Audio (s) | Synthese (s) | RTF | × Echtzeit | Zeichen/s | Pegel (dBFS RMS) | längste Pause (s) | Segmente |\n|---|---|---|---|---|---|---|---|---|\n"
        for m in measurements {
            table += String(format: "| %@ | %.1f | %.1f | %.3f | %.1f | %.1f | %.1f | %.2f | %d |\n",
                            m.label, m.audioSeconds, m.synthesisSeconds, m.realTimeFactor, 1 / m.realTimeFactor,
                            m.charactersPerSecond, m.rmsDB, m.longestInternalPause, m.segments)
        }
        if !skipped.isEmpty { table += "\nNicht installiert/übersprungen: \(skipped.joined(separator: ", "))\n" }
        try table.write(to: outputDirectory.appendingPathComponent("messwerte.md"), atomically: true, encoding: .utf8)
        print("AUDIO_SAMPLES_DIR \(outputDirectory.path)\n\(table)")
    }

    // MARK: - Analysis helpers

    static func analyze(_ url: URL) throws -> (duration: Double, rmsDB: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        _ = format
        let samples = buffer.floatChannelData![0]
        var sum = 0.0
        for index in 0..<Int(buffer.frameLength) { sum += Double(samples[index] * samples[index]) }
        let rms = sqrt(sum / Double(max(buffer.frameLength, 1)))
        return (Double(file.length) / file.processingFormat.sampleRate, 20 * log10(max(rms, 1e-9)))
    }

    /// Silences ≥ 0.8 s that are *inside* the audio (leading/trailing
    /// silence excluded), via ffmpeg's silencedetect.
    static func internalPauses(_ url: URL) async throws -> [Double] {
        guard let ffmpeg = FFmpegLocator.resolve(settings: AppSettings()) else { throw XCTSkip("ffmpeg missing") }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-i", url.path, "-af", "silencedetect=noise=-45dB:d=0.8", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)
        let duration = try analyze(url).duration

        var pauses: [Double] = []
        var start: Double?
        for line in log.split(separator: "\n") {
            if let range = line.range(of: "silence_start: ") {
                start = Double(line[range.upperBound...].split(separator: " ").first ?? "")
            } else if let range = line.range(of: "silence_end: ") {
                let parts = line[range.upperBound...].split(separator: " ")
                guard let end = Double(parts.first ?? ""), let begin = start else { continue }
                if begin > 0.05 && end < duration - 0.05 { pauses.append(end - begin) }
                start = nil
            }
        }
        return pauses
    }
}
