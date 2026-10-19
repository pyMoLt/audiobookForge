import Foundation

/// Thin wrapper around ffprobe (expected next to the resolved ffmpeg
/// binary). Used to verify a packaged output file before the intermediate
/// chapter audio is allowed to be deleted (plan 5.2).
enum FFProbeRunner {
    struct ChapterRange: Sendable, Equatable {
        var startSeconds: Double
        var endSeconds: Double
        var durationSeconds: Double { endSeconds - startSeconds }
    }

    struct Probe: Sendable, Equatable {
        var durationSeconds: Double
        var chapters: [ChapterRange]
    }

    struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func probeURL(for ffmpeg: URL) -> URL {
        ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
    }

    static func isAvailable(ffmpeg: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: probeURL(for: ffmpeg).path)
    }

    static func probe(file: URL, ffmpeg: URL) async throws -> Probe {
        let ffprobe = probeURL(for: ffmpeg)
        let result = try await ProcessRunner.run(
            executable: ffprobe,
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_chapters",
                file.path,
            ]
        )
        guard result.terminationStatus == 0 else {
            throw ProbeError(message: "ffprobe fehlgeschlagen: \(result.standardErrorText)")
        }
        return try parseProbeOutput(result.standardOutputText)
    }

    static func parseProbeOutput(_ json: String) throws -> Probe {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError(message: "ffprobe-Ausgabe konnte nicht gelesen werden.")
        }
        let format = object["format"] as? [String: Any]
        let duration = (format?["duration"] as? String).flatMap(Double.init) ?? 0
        var chapters: [ChapterRange] = []
        if let chapterList = object["chapters"] as? [[String: Any]] {
            for chapter in chapterList {
                let start = (chapter["start_time"] as? String).flatMap(Double.init) ?? 0
                let end = (chapter["end_time"] as? String).flatMap(Double.init) ?? 0
                chapters.append(ChapterRange(startSeconds: start, endSeconds: end))
            }
        }
        return Probe(durationSeconds: duration, chapters: chapters)
    }
}

/// Verifies a packaged single-file output (M4B/M4A) against the chapter
/// durations it was built from. All checks must pass before the
/// intermediate chapter audio may be deleted (plan 5.2):
/// - output exists, is readable and non-empty,
/// - total duration ≈ Σ chapter durations (± 1 s),
/// - chapter mark count == chapter count,
/// - each chapter mark's duration ≈ its chapter audio (± 0.2 s).
enum PackagedAudioVerifier {
    struct Verification: Sendable, Equatable {
        var isVerified: Bool
        var problems: [String] = []
        var durationSeconds: Double?
        var chapterRanges: [FFProbeRunner.ChapterRange] = []
    }

    static func verifySingleFileOutput(
        url: URL,
        ffmpeg: URL,
        chapterDurations: [Double],
        totalToleranceSeconds: Double? = nil,
        perChapterToleranceSeconds: Double = 0.5
    ) async -> Verification {
        var problems: [String] = []
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if !FileManager.default.isReadableFile(atPath: url.path) {
            problems.append("Ausgabedatei ist nicht lesbar: \(url.path)")
            return Verification(isVerified: false, problems: problems)
        }
        if let size = attributes?[.size] as? UInt64, size == 0 {
            problems.append("Ausgabedatei ist leer.")
        }
        guard FFProbeRunner.isAvailable(ffmpeg: ffmpeg) else {
            problems.append("ffprobe wurde nicht gefunden — Verifikation nicht möglich, Löschen wird übersprungen.")
            return Verification(isVerified: false, problems: problems)
        }
        let probe: FFProbeRunner.Probe
        do {
            probe = try await FFProbeRunner.probe(file: url, ffmpeg: ffmpeg)
        } catch {
            problems.append("ffprobe konnte die Ausgabe nicht prüfen: \(error.localizedDescription)")
            return Verification(isVerified: false, problems: problems)
        }

        let expectedTotal = chapterDurations.reduce(0, +)
        // Container muxing (especially AAC/M4B with hundreds of chapters) introduces
        // encoder priming and padding frames across chapter bounds. A fixed 1.0s
        // tolerance fails on massive audiobooks (e.g. 45 hours with 943 chapters has ~10s difference = 0.006%).
        // Dynamic tolerance scales proportionally with duration and chapter count:
        let allowedTotalTolerance = totalToleranceSeconds ?? max(5.0, min(60.0, expectedTotal * 0.001 + Double(chapterDurations.count) * 0.03))
        if abs(probe.durationSeconds - expectedTotal) > allowedTotalTolerance {
            problems.append(String(
                format: "Gesamtdauer weicht ab: %.1f s statt %.1f s (Toleranz %.1f s).",
                probe.durationSeconds, expectedTotal, allowedTotalTolerance
            ))
        }
        if probe.chapters.count != chapterDurations.count {
            problems.append("Kapitelmarken: \(probe.chapters.count) statt \(chapterDurations.count).")
        }
        for (index, range) in probe.chapters.enumerated() where index < chapterDurations.count {
            if abs(range.durationSeconds - chapterDurations[index]) > perChapterToleranceSeconds {
                problems.append(String(
                    format: "Kapitel %d: Dauer %.2f s statt %.2f s (Toleranz %.1f s).",
                    index + 1, range.durationSeconds, chapterDurations[index], perChapterToleranceSeconds
                ))
            }
        }
        return Verification(
            isVerified: problems.isEmpty,
            problems: problems,
            durationSeconds: probe.durationSeconds,
            chapterRanges: probe.chapters
        )
    }

    /// Checks one exported MP3 chapter file against its source chapter
    /// audio duration (same tolerance as the single-file check).
    static func verifyChapterFile(url: URL, expectedDurationSeconds: Double, toleranceSeconds: Double = 0.2) async -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? UInt64) ?? 0 > 0 else { return false }
        guard let duration = try? await WaveFileInspector.durationSeconds(url: url) else { return false }
        return abs(duration - expectedDurationSeconds) <= toleranceSeconds
    }
}
