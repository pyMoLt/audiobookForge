import Foundation
import XCTest
@testable import AudiobookForge

/// Real end-to-end run through `PipelineController` — real PDF, real local
/// LLM (oMLX), real TTS, real M4B — against isolated library/settings
/// files. Opt-in because it needs a running oMLX server and takes minutes:
///   TEST_RUNNER_ABF_E2E_OMLX_URL=http://127.0.0.1:8010/v1
///   TEST_RUNNER_ABF_E2E_MODEL=Qwen3.6-35B-A3B-UD-MLX-4bit
///   TEST_RUNNER_ABF_E2E_PDF=/path/to/paper.pdf
///   TEST_RUNNER_ABF_E2E_OUTPUT=/path/to/output   (optional)
///   TEST_RUNNER_ABF_E2E_THINKING=off|on           (optional, default off)
@MainActor
final class RealEndToEndTests: XCTestCase {
    func testPDFSummaryThroughOMLXToM4B() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let baseURL = env["ABF_E2E_OMLX_URL"], let model = env["ABF_E2E_MODEL"], let pdfPath = env["ABF_E2E_PDF"] else {
            throw XCTSkip("ABF_E2E_* environment not set")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("abf-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let outputBase = env["ABF_E2E_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? work.appendingPathComponent("out")

        let settingsStore = SettingsStore(fileURL: work.appendingPathComponent("settings.json"))
        var settings = AppSettings()
        settings.llmProvider = .omlx
        settings.omlxBaseURL = baseURL
        settings.omlxModel = model
        settings.omlxGeneration.thinkingMode = env["ABF_E2E_THINKING"] == "on" ? .on : .off
        settings.describeImagesWithVisionModel = false
        settings.outputBaseFolderPath = outputBase.path
        settingsStore.settings = settings
        let libraryStore = LibraryStore(fileURL: work.appendingPathComponent("library.json"))
        let controller = PipelineController(libraryStore: libraryStore, settingsStore: settingsStore)

        var book = try await DocumentImportService.importDocument(at: URL(fileURLWithPath: pdfPath), settings: settings)
        book.mode = .summary
        book.documentType = .paper
        book.outputFormat = .m4b
        book.engineID = .kokoro
        book.voice = "af_heart"
        book.speechSpeed = 1.0
        let sourceCharacters = book.chapters.reduce(0) { $0 + $1.cleanedText.count }
        libraryStore.upsert(book)
        defer { try? FileManager.default.removeItem(at: AppPaths.chapterAudioDirectory(bookID: book.id)) }

        // Sample live progress while the run executes.
        var samples: [(stage: PipelineStage, overall: Double)] = []
        let started = Date()
        controller.enqueue(bookID: book.id)
        while controller.isRunning(book.id) {
            if let progress = controller.progress[book.id] {
                if samples.last?.stage != progress.stage || abs((samples.last?.overall ?? -1) - progress.overallFraction) > 0.01 {
                    samples.append((progress.stage, progress.overallFraction))
                }
            }
            try await Task.sleep(for: .milliseconds(250))
            if Date().timeIntervalSince(started) > 3600 { XCTFail("timeout"); break }
        }
        let elapsed = Date().timeIntervalSince(started)

        let finished = try XCTUnwrap(libraryStore.book(id: book.id))
        XCTAssertEqual(finished.status, .completed, finished.lastErrorMessage ?? "")
        XCTAssertGreaterThan(finished.chapters.count, 1, "AI should structure the paper into several chapters")
        let summaryCharacters = finished.chapters.reduce(0) { $0 + ($1.summarizedText?.count ?? 0) }
        XCTAssertGreaterThan(summaryCharacters, sourceCharacters / 10, "summary implausibly short")
        XCTAssertLessThan(summaryCharacters, sourceCharacters, "summary should be shorter than the source")
        for chapter in finished.chapters {
            let text = chapter.summarizedText ?? ""
            XCTAssertFalse(text.contains("<think>") || text.contains("</think>"), "reasoning leaked into \(chapter.title)")
            XCTAssertEqual(chapter.audioStatus, .ready)
        }

        // Progress must only move forward and reach the synthesis phase.
        let overall = samples.map(\.overall)
        XCTAssertEqual(overall, overall.sorted(), "overall progress went backwards: \(overall)")
        XCTAssertTrue(samples.contains { $0.stage == .summarizing })
        XCTAssertTrue(samples.contains { $0.stage == .synthesizing })

        // The exported M4B carries one chapter mark per AI chapter.
        let outputDirectory = try XCTUnwrap(finished.outputDirectoryURL)
        let m4b = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil).first { $0.pathExtension == "m4b" })
        let ffprobe = try XCTUnwrap(FFmpegLocator.resolve(settings: settings)).deletingLastPathComponent().appendingPathComponent("ffprobe")
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-show_chapters", "-show_entries", "format=duration", "-of", "json", m4b.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let probe = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let chapters = probe["chapters"] as? [[String: Any]] ?? []
        let duration = Double(((probe["format"] as? [String: Any])?["duration"] as? String) ?? "0") ?? 0
        XCTAssertEqual(chapters.count, finished.chapters.count)
        XCTAssertGreaterThan(duration, 60)

        let logText = (try? String(contentsOf: try XCTUnwrap(finished.logFileURL), encoding: .utf8)) ?? ""
        let report = """
        E2E_REPORT
        model=\(model) thinking=\(settings.omlxGeneration.thinkingMode.rawValue)
        source_chars=\(sourceCharacters) summary_chars=\(summaryCharacters) ratio=\(String(format: "%.1f%%", Double(summaryCharacters) / Double(sourceCharacters) * 100))
        ai_chapters=\(finished.chapters.count): \(finished.chapters.map(\.title).joined(separator: " | "))
        m4b=\(m4b.path) duration=\(String(format: "%.0f", duration))s chapter_marks=\(chapters.count)
        wall=\(String(format: "%.0f", elapsed))s progress_samples=\(samples.count)
        --- log ---
        \(logText)
        """
        try report.write(to: outputDirectory.appendingPathComponent("e2e-report.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    /// Real oMLX: the same 4 book chapters summarized with 1 and with 2
    /// concurrent requests. Same order either way; 2 must be faster.
    func testParallelSummaryAgainstOMLXIsFasterAndKeepsOrder() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let baseURL = env["ABF_E2E_OMLX_URL"], let model = env["ABF_E2E_MODEL"], let pdfPath = env["ABF_E2E_PDF"] else {
            throw XCTSkip("ABF_E2E_* environment not set")
        }
        var settings = AppSettings()
        settings.llmProvider = .omlx
        settings.omlxBaseURL = baseURL
        settings.omlxModel = model
        settings.omlxGeneration.thinkingMode = .off
        settings.omlxGeneration.temperature = 0.3
        let book = try await DocumentImportService.importDocument(at: URL(fileURLWithPath: pdfPath), settings: settings)
        let chapters = book.chapters.sorted { $0.order < $1.order }.filter { $0.cleanedText.count > 1200 }.prefix(4).map { (title: $0.title, text: $0.cleanedText) }
        XCTAssertEqual(chapters.count, 4)

        var timings: [Int: Double] = [:]
        for parallel in [1, 2] {
            settings.omlxParallelRequests = parallel
            let started = Date()
            let result = try await SummarizerClient(settings: settings).summarizeIntoChapters(bookTitle: book.title, chapters: Array(chapters), documentType: .book, characterBudget: 50_000)
            timings[parallel] = Date().timeIntervalSince(started)
            let parents = result.map { $0.title.components(separatedBy: " — ").first ?? $0.title }
            var order: [String] = []
            for parent in parents where order.last != parent { order.append(parent) }
            XCTAssertEqual(order, chapters.map(\.title), "parallel=\(parallel) changed chapter order")
        }
        print("PARALLEL_TIMINGS 1=\(String(format: "%.1f", timings[1]!))s 2=\(String(format: "%.1f", timings[2]!))s")
        XCTAssertLessThan(timings[2]!, timings[1]!)
    }
}
