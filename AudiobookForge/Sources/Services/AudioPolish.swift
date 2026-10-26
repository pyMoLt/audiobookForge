import Foundation

/// The audio chain between the engine and the chapter file (v4.4):
/// optional clean-up, then loudness — either calm (one fixed gain per
/// chapter plus a peak limiter) or dynamic (EBU R128 loudnorm). Pure
/// argument builders and parsers, so the tests need no ffmpeg.
enum AudioPolish {
    /// Light clean-up: remove clicks, a mild denoise below the noise floor,
    /// +2 dB presence above 5 kHz (neural codecs sound a little dull).
    static let enhancementFilter = "adeclick,afftdn=nr=8:nf=-45,highshelf=f=5000:g=2"

    /// The pre-4.4 single-pass loudnorm (rides the gain, resamples to 192 kHz).
    static func dynamicLoudnessFilter(_ settings: AppSettings) -> String {
        "loudnorm=I=\(settings.loudnessTargetLUFS):TP=\(settings.loudnessTruePeakDB):LRA=\(settings.loudnessRangeLU)"
    }

    /// Calm normalization: a fixed gain and a soft limiter at the peak limit.
    static func calmFilter(gainDB: Double, truePeakDB: Double) -> String {
        let limit = min(1, max(0.0625, pow(10, truePeakDB / 20)))
        return String(format: "volume=%.2fdB,alimiter=limit=%.4f:attack=5:release=50:level=disabled", gainDB, limit)
    }

    /// True when chapters go through a measured second pass.
    static func usesCalmPass(_ settings: AppSettings) -> Bool {
        settings.loudnessNormalizationEnabled && settings.loudnessMode == .calm
    }

    /// Filters for the streaming pass: clean-up, and loudnorm when dynamic.
    static func streamingFilters(_ settings: AppSettings) -> [String] {
        var filters: [String] = []
        if settings.audioEnhancementEnabled { filters.append(enhancementFilter) }
        if settings.loudnessNormalizationEnabled, settings.loudnessMode == .dynamic {
            filters.append(dynamicLoudnessFilter(settings))
        }
        return filters
    }

    /// Gain that brings `measuredLUFS` to the target; 0 for silence.
    static func calmGain(measuredLUFS: Double?, targetLUFS: Double) -> Double {
        guard let measured = measuredLUFS, measured.isFinite, measured > -70 else { return 0 }
        return min(30, max(-20, targetLUFS - measured))
    }

    /// Codec arguments for a chapter file (the extension picks the codec).
    static func codecArguments(for outputURL: URL, settings: AppSettings) throws -> [String] {
        switch outputURL.pathExtension.lowercased() {
        case "m4a":
            return ["-c:a", "aac", "-b:a", "\(max(16, settings.aacBitrateKbps))k", "-f", "ipod", outputURL.path]
        case "mp3":
            // v4.1: final ID3 tags on the first encode (see ChapterAudioTags).
            let tags = ChapterAudioTags.tag(for: outputURL)?.ffmpegArguments ?? []
            return ["-c:a", "libmp3lame", "-qscale:a", String(settings.mp3Quality)] + tags + [outputURL.path]
        default:
            throw ChapterAudioEncoder.EncoderError.unsupportedOutput(outputURL.pathExtension)
        }
    }

    // MARK: Measuring

    /// Integrated loudness and true peak from ffmpeg's ebur128 summary.
    struct Loudness: Equatable {
        var integratedLUFS: Double?
        var truePeakDB: Double?
    }

    static func parseLoudness(_ lines: [String]) -> Loudness {
        var result = Loudness()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("I:") { result.integratedLUFS = firstNumber(in: trimmed) }
            if trimmed.hasPrefix("Peak:") { result.truePeakDB = firstNumber(in: trimmed) }
        }
        return result
    }

    static func measureLoudness(of url: URL, ffmpeg: URL) async throws -> Loudness {
        let lines = LockedBox<[String]>([])
        try await FFmpegRunner.run(
            executable: ffmpeg,
            arguments: ["-hide_banner", "-nostats", "-i", url.path, "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"],
            onOutput: { line in lines.withLock { $0.append(line) } }
        )
        return parseLoudness(lines.withLock { $0 })
    }

    /// First decimal number in a line ("-inf" counts as none).
    static func firstNumber(in text: String) -> Double? {
        let pattern = /-?\d+(?:\.\d+)?/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return Double(match.output)
    }
}

/// Quality check per chapter (v4.4): measures the finished chapter file and
/// names what an ear would notice — peaks at the limit, possible clicks,
/// long silences, loudness far from the target. Writes to the run log only;
/// the audio is not touched.
struct ChapterQualityReport: Equatable {
    var integratedLUFS: Double?
    var truePeakDB: Double?
    var samplePeakDB: Double?
    var peakCount: Int = 0
    var maxDifference: Double?
    var silences: [Double] = []

    /// Longest silence that still counts as a pause (headings, lead-ins).
    static let longSilenceSeconds = 4.0
    /// Sample-to-sample jump (of full scale) that speech does not make.
    static let clickJump = 0.6

    func findings(targetLUFS: Double?) -> [String] {
        var result: [String] = []
        if let peak = samplePeakDB, peak >= -0.1, peakCount > 3 {
            result.append(String(format: L("mögliche Übersteuerung (%d Samples am Maximum)"), peakCount))
        } else if let peak = truePeakDB, peak > -0.5 {
            result.append(String(format: L("Spitzen nahe der Grenze (%.1f dBTP)"), peak))
        }
        if let jump = maxDifference, jump > Self.clickJump {
            result.append(L("möglicher Knackser (sehr steiler Sprung im Signal)"))
        }
        let long = silences.filter { $0 >= Self.longSilenceSeconds }
        if let longest = long.max() {
            result.append(String(format: L("%d lange Stille(n), längste %.1f s"), long.count, longest))
        }
        if let target = targetLUFS, let loudness = integratedLUFS, abs(loudness - target) > 3 {
            result.append(String(format: L("Lautheit %.1f LUFS statt %.1f"), loudness, target))
        }
        return result
    }

    func logLine(chapter: String, targetLUFS: Double?) -> String {
        let measured = [
            integratedLUFS.map { String(format: "%.1f LUFS", $0) },
            truePeakDB.map { String(format: L("Spitze %.1f dBTP"), $0) },
        ].compactMap { $0 }.joined(separator: ", ")
        let findings = findings(targetLUFS: targetLUFS)
        let verdict = findings.isEmpty ? L("in Ordnung") : L("auffällig") + " — " + findings.joined(separator: "; ")
        return String(format: L("  Qualität %@: %@ (%@)"), chapter, verdict, measured)
    }

    static func parse(_ lines: [String]) -> ChapterQualityReport {
        let loudness = AudioPolish.parseLoudness(lines)
        var report = ChapterQualityReport(integratedLUFS: loudness.integratedLUFS, truePeakDB: loudness.truePeakDB)
        for line in lines {
            if let range = line.range(of: "Peak level dB:") {
                report.samplePeakDB = AudioPolish.firstNumber(in: String(line[range.upperBound...]))
            } else if let range = line.range(of: "Peak count:") {
                report.peakCount = Int(AudioPolish.firstNumber(in: String(line[range.upperBound...])) ?? 0)
            } else if let range = line.range(of: "Max difference:") {
                report.maxDifference = AudioPolish.firstNumber(in: String(line[range.upperBound...]))
            } else if let range = line.range(of: "silence_duration:") {
                if let seconds = AudioPolish.firstNumber(in: String(line[range.upperBound...])) { report.silences.append(seconds) }
            }
        }
        return report
    }

    static func analyze(url: URL, ffmpeg: URL) async throws -> ChapterQualityReport {
        let lines = LockedBox<[String]>([])
        let filters = "ebur128=peak=true:framelog=quiet,silencedetect=n=-55dB:d=\(longSilenceSeconds),"
            + "astats=measure_perchannel=none:measure_overall=Peak_level+Max_difference+Peak_count"
        try await FFmpegRunner.run(
            executable: ffmpeg,
            arguments: ["-hide_banner", "-nostats", "-i", url.path, "-af", filters, "-f", "null", "-"],
            onOutput: { line in lines.withLock { $0.append(line) } }
        )
        return parse(lines.withLock { $0 })
    }
}

extension ChapterQualityReport {
    /// Runs the check on a finished chapter file and writes one log line.
    /// Never fails the chapter: a check that cannot run is only noted.
    static func check(_ url: URL, chapter: String, settings: AppSettings, logger: RunLogger) async {
        guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settings) else { return }
        do {
            let report = try await analyze(url: url, ffmpeg: ffmpeg)
            let target = settings.loudnessNormalizationEnabled ? settings.loudnessTargetLUFS : nil
            logger.log(report.logLine(chapter: chapter, targetLUFS: target))
        } catch is CancellationError {
            return
        } catch {
            logger.log(String(format: L("  Qualitätscheck %@ nicht möglich: %@"), chapter, error.localizedDescription))
        }
    }
}
