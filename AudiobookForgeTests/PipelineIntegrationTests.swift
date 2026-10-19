import XCTest
@testable import AudiobookForge

/// End-to-end tests that exercise the real Kokoro bridge (mlx-audio
/// subprocess) and real ffmpeg, not mocks. These are slower and require the
/// bridge environment + ffmpeg to be present on the machine running the
/// tests, which is true for the development Mac this project targets.
final class PipelineIntegrationTests: XCTestCase {
    private var settings: AppSettings!

    override func setUpWithError() throws {
        settings = AppSettings()
        // These tests use deliberately tiny synthetic chapters to keep real
        // TTS synthesis fast — disable the (real-world-oriented) minimum
        // chapter length merge so that stays two distinct chapters, not one.
        settings.minimumChapterCharacters = 0
    }

    func testPiperEnvironmentCanBeSetUpAndSynthesizesGermanAudio() async throws {
        let environment = PiperEnvironmentManager.shared
        if !environment.isEnvironmentReady() {
            try await environment.runSetup { _ in }
        }
        XCTAssertTrue(environment.isEnvironmentReady())

        let voice = PiperVoiceCatalog.voice(id: "de_DE-thorsten-medium")!
        if !environment.isVoiceDownloaded(voice.id) {
            try await environment.downloadVoice(voice) { _ in }
        }
        XCTAssertTrue(environment.isVoiceDownloaded(voice.id))

        let engine = PiperEngine(settings: settings, environment: environment)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("piper-integration-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let progressState = LockedBox<Int>(0)
        let multiSentenceText = "Hallo, dies ist ein automatisierter Test der deutschen Thorsten-Stimme mit Piper. Der Text besteht aus mehreren Sätzen. So lässt sich prüfen, ob die satzweise Synthese und das anschließende Zusammenfügen sauber funktionieren."
        let result = try await engine.synthesize(
            text: multiSentenceText,
            voice: voice.id,
            speed: 1.0,
            outputURL: outputURL,
            onProgress: { _ in progressState.withLock { $0 += 1 } }
        )

        XCTAssertGreaterThan(progressState.withLock { $0 }, 0)
        XCTAssertGreaterThan(result.durationSeconds, 0)
        XCTAssertEqual(result.segmentCount, 3, "Expected one segment per sentence")
        XCTAssertEqual(result.segments?.count, 3)
        XCTAssertEqual(result.segments?.first?.text, "Hallo, dies ist ein automatisierter Test der deutschen Thorsten-Stimme mit Piper.")
        // Segments should be laid out back-to-back in order with no gaps/overlaps.
        if let segments = result.segments {
            for (index, segment) in segments.enumerated() where index > 0 {
                XCTAssertEqual(segment.startSeconds, segments[index - 1].startSeconds + segments[index - 1].durationSeconds, accuracy: 0.05)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let concatenatedDuration = try await WaveFileInspector.durationSeconds(url: outputURL)
        XCTAssertEqual(concatenatedDuration, result.durationSeconds, accuracy: 0.2, "Encoded chapter file duration should match the sum of segment durations")
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 1000)
    }

    func testBridgeEnvironmentCanBeSetUp() async throws {
        let bridge = BridgeEnvironmentManager.shared
        if !bridge.isEnvironmentReady() {
            let lastLine = LockedBox<String>("")
            try await bridge.runSetup { line in lastLine.withLock { $0 = line } }
            XCTAssertTrue(lastLine.withLock { $0.hasPrefix("DONE") } || bridge.isEnvironmentReady(), "Setup should finish successfully")
        }
        XCTAssertTrue(bridge.isEnvironmentReady())
    }

    func testKokoroSynthesizesRealAudio() async throws {
        let bridge = BridgeEnvironmentManager.shared
        try XCTSkipUnless(bridge.isEnvironmentReady(), "Bridge environment not set up; run testBridgeEnvironmentCanBeSetUp first")

        let engine = KokoroEngine(settings: settings, bridge: bridge)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("integration-\(UUID().uuidString).m4a")

        let progressState = LockedBox<(sawModelLoaded: Bool, segmentCount: Int)>((false, 0))

        let result = try await engine.synthesize(
            text: "This is an automated integration test of the Kokoro text to speech engine. It should produce a short, real audio file.",
            voice: "af_heart",
            speed: 1.0,
            outputURL: outputURL,
            onProgress: { event in
                switch event {
                case .modelLoaded: progressState.withLock { $0.sawModelLoaded = true }
                case .segmentDone: progressState.withLock { $0.segmentCount += 1 }
                case .plannedSegments: break
                }
            }
        )

        defer { try? FileManager.default.removeItem(at: outputURL) }

        let (sawModelLoaded, segmentCount) = progressState.withLock { $0 }
        XCTAssertTrue(sawModelLoaded)
        XCTAssertGreaterThan(segmentCount, 0)
        XCTAssertGreaterThan(result.durationSeconds, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 1000, "Expected a real, non-trivial compressed chapter file")
    }

    func testFullPipelineProducesMP3Chapters() async throws {
        let bridge = BridgeEnvironmentManager.shared
        try XCTSkipUnless(bridge.isEnvironmentReady(), "Bridge environment not set up; run testBridgeEnvironmentCanBeSetUp first")
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }

        let pdfURL = TestPDFBuilder.makeSingleColumnBookWithOutline(
            title: "Integration Test Book",
            author: "Test Author",
            chapters: [
                (title: "Chapter One", body: "The pipeline begins with a short first chapter, just long enough to synthesize quickly."),
                (title: "Chapter Two", body: "The second chapter wraps things up, also kept short so the test runs fast."),
            ]
        )
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var book = try await DocumentImportService.importDocument(at: pdfURL, settings: settings)
        book.outputFormat = .mp3Chapters
        XCTAssertEqual(book.chapters.count, 2)

        let engine = KokoroEngine(settings: settings, bridge: bridge)
        let audioDirectory = AppPaths.chapterAudioDirectory(bookID: book.id)
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        var chapterAudioFiles: [ChapterAudioFile] = []
        for index in book.chapters.indices {
            let chapter = book.chapters[index]
            let outputURL = ChapterAudioStore.chapterFileURL(bookID: book.id, order: chapter.order, format: book.outputFormat)
            let result = try await engine.synthesize(text: chapter.textForNarration, voice: "af_heart", speed: 1.2, outputURL: outputURL, onProgress: { _ in })
            book.chapters[index].audioFileURL = result.audioFileURL
            book.chapters[index].audioDurationSeconds = result.durationSeconds
            chapterAudioFiles.append(ChapterAudioFile(chapter: book.chapters[index], url: result.audioFileURL))
        }

        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-output-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let packager = MP3ChapterPackager(settings: settings)
        let finalDirectory = try await packager.package(book: book, chapterAudioFiles: chapterAudioFiles, outputDirectory: outputDirectory, onProgress: { _ in })

        let mp3Files = try FileManager.default.contentsOfDirectory(at: finalDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertEqual(mp3Files.count, 2)
        for file in mp3Files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = attributes[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 1000)
        }
        XCTAssertTrue(mp3Files[0].lastPathComponent.contains("Chapter One"))
        XCTAssertTrue(mp3Files[1].lastPathComponent.contains("Chapter Two"))
    }

    func testFullPipelineProducesM4BWithChapters() async throws {
        let bridge = BridgeEnvironmentManager.shared
        try XCTSkipUnless(bridge.isEnvironmentReady(), "Bridge environment not set up; run testBridgeEnvironmentCanBeSetUp first")
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }

        let pdfURL = TestPDFBuilder.makeSingleColumnBookWithOutline(
            title: "M4B Integration Test",
            author: "Test Author",
            chapters: [
                (title: "Opening", body: "A very short opening chapter for the M4B packaging integration test."),
                (title: "Closing", body: "And a very short closing chapter to make sure chapter marks land correctly."),
            ]
        )
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var book = try await DocumentImportService.importDocument(at: pdfURL, settings: settings)
        book.outputFormat = .m4b

        let engine = KokoroEngine(settings: settings, bridge: bridge)
        let audioDirectory = AppPaths.chapterAudioDirectory(bookID: book.id)
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        var chapterAudioFiles: [ChapterAudioFile] = []
        for index in book.chapters.indices {
            let chapter = book.chapters[index]
            let outputURL = ChapterAudioStore.chapterFileURL(bookID: book.id, order: chapter.order, format: book.outputFormat)
            let result = try await engine.synthesize(text: chapter.textForNarration, voice: "af_heart", speed: 1.3, outputURL: outputURL, onProgress: { _ in })
            book.chapters[index].audioFileURL = result.audioFileURL
            chapterAudioFiles.append(ChapterAudioFile(chapter: book.chapters[index], url: result.audioFileURL))
        }

        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("integration-output-m4b-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let packager = MP4ChapterPackager(settings: settings, format: .m4b)
        let finalURL = try await packager.package(book: book, chapterAudioFiles: chapterAudioFiles, outputDirectory: outputDirectory, onProgress: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(finalURL.pathExtension, "m4b")

        let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 2000)

        // Verify chapters were actually embedded by asking ffprobe (ships alongside ffmpeg).
        let ffmpegURL = FFmpegLocator.resolve(settings: settings)!
        let ffprobeURL = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe")
        if FileManager.default.isExecutableFile(atPath: ffprobeURL.path) {
            let process = Process()
            process.executableURL = ffprobeURL
            process.arguments = ["-v", "error", "-show_chapters", finalURL.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(output.contains("TAG:title=Opening"), output)
            XCTAssertTrue(output.contains("TAG:title=Closing"), output)
        }
    }

    /// The old pipeline ran loudness normalization as a separate ffmpeg
    /// pass that wrote a second full WAV per chapter. The streaming rework
    /// folds loudnorm into the single encode pass — this test verifies the
    /// chapter comes out compressed, at the right duration, and that no
    /// uncompressed WAV intermediate is created anywhere.
    func testLoudnessIsAppliedInSingleEncodePassWithoutWAVIntermediate() async throws {
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }
        let bridge = BridgeEnvironmentManager.shared
        try XCTSkipUnless(bridge.isEnvironmentReady(), "Bridge environment not set up; run testBridgeEnvironmentCanBeSetUp first")

        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("loudnorm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let engine = KokoroEngine(settings: settings, bridge: bridge)
        let m4aURL = outputDirectory.appendingPathComponent("000.m4a")

        let result = try await engine.synthesize(
            text: "This sentence gets normalized to a consistent loudness level while it is being encoded.",
            voice: "af_heart",
            speed: 1.0,
            outputURL: m4aURL,
            onProgress: { _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: m4aURL.path))
        let fileDuration = try await WaveFileInspector.durationSeconds(url: m4aURL)
        XCTAssertEqual(fileDuration, result.durationSeconds, accuracy: 0.3, "Normalization shouldn't meaningfully change duration")

        // The compressed chapter must be far smaller than the raw PCM it
        // was synthesized from (24 kHz · 2 bytes · duration).
        let attributes = try FileManager.default.attributesOfItem(atPath: m4aURL.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
        let rawPCMBytes = result.durationSeconds * 24000 * 2
        XCTAssertLessThan(Double(size), rawPCMBytes * 0.2, "Chapter file should be compressed, not raw PCM sized")

        // No WAV intermediate may remain anywhere in the output directory.
        let leftovers = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
        XCTAssertTrue(leftovers.isEmpty, "No uncompressed WAV intermediates may be left behind")
    }

    /// True end-to-end storage verification: a small book through the real
    /// `PipelineController` (transcription mode, no LLM), then the chapter
    /// audio directory is inspected — only small compressed .m4a files may
    /// exist, no WAV, no leftover normalization copy, and the final M4B
    /// must be built.
    @MainActor
    func testFullPipelineRunWritesOnlyCompressedChapterAudio() async throws {
        let bridge = BridgeEnvironmentManager.shared
        try XCTSkipUnless(bridge.isEnvironmentReady(), "Bridge environment not set up; run testBridgeEnvironmentCanBeSetUp first")
        guard FFmpegLocator.resolve(settings: settings) != nil else {
            throw XCTSkip("ffmpeg not found on this machine")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let settingsStore = SettingsStore(fileURL: work.appendingPathComponent("settings.json"))
        settings.outputBaseFolderPath = work.appendingPathComponent("out").path
        // This test inspects the chapter audio directory after packaging —
        // since Phase 2 the pipeline deletes it by default
        // (`keepChapterAudioAfterPackaging = false`), so keep it here.
        settings.keepChapterAudioAfterPackaging = true
        settingsStore.settings = settings
        let libraryStore = LibraryStore(fileURL: work.appendingPathComponent("library.json"))

        let pdfURL = TestPDFBuilder.makeSingleColumnBookWithOutline(
            title: "Storage E2E",
            author: "Test Author",
            chapters: [
                (title: "Einleitung", body: "Eine kurze Einleitung, um die Speicherreduktion zu prüfen."),
                (title: "Fazit", body: "Ein kurzes Fazit beendet das kleine Testbuch.")
            ]
        )
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var book = try await DocumentImportService.importDocument(at: pdfURL, settings: settings)
        book.mode = .transcription
        book.outputFormat = .m4b
        book.engineID = .kokoro
        book.voice = "af_heart"
        libraryStore.upsert(book)

        let controller = PipelineController(libraryStore: libraryStore, settingsStore: settingsStore)
        controller.enqueue(bookID: book.id)

        // Wait for the pipeline to finish (small book: well under a minute).
        for _ in 0..<240 {
            if let current = libraryStore.book(id: book.id), current.status != .processing, current.status != .queued { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let finished = libraryStore.book(id: book.id)
        XCTAssertEqual(finished?.status, .completed, "Pipeline should complete; last error: \(finished?.lastErrorMessage ?? "-")")

        // The final M4B must exist and carry both chapter marks.
        let finalURL = finished?.outputDirectoryURL
        XCTAssertNotNil(finalURL)
        let m4bURL = try FileManager.default.contentsOfDirectory(at: finalURL!, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4b" }.first
        XCTAssertNotNil(m4bURL, "Final M4B must be built")

        // The chapter audio directory must contain ONLY compressed chapters.
        let chapterDirectory = AppPaths.chapterAudioDirectory(bookID: book.id)
        defer { try? FileManager.default.removeItem(at: chapterDirectory) }
        let chapterFiles = try FileManager.default.contentsOfDirectory(at: chapterDirectory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertFalse(chapterFiles.isEmpty)

        var totalBytes = 0
        var totalSeconds = 0.0
        for file in chapterFiles {
            let ext = file.pathExtension.lowercased()
            XCTAssertTrue(["m4a", "mp3"].contains(ext), "Unexpected chapter file type: \(file.lastPathComponent)")
            XCTAssertFalse(ext == "wav", "No WAV intermediate may remain")
            XCTAssertFalse(file.lastPathComponent.contains("normalized"), "No second-pass normalization copy may remain")
            totalBytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalSeconds += (try? await WaveFileInspector.durationSeconds(url: file)) ?? 0
        }

        // Compressed, not PCM sized: 24 kHz mono PCM would be ~48 KB/s.
        let rawEquivalent = totalSeconds * 48000
        XCTAssertGreaterThan(rawEquivalent, 0)
        XCTAssertLessThan(Double(totalBytes), rawEquivalent * 0.25, "Chapter audio must be a small fraction of the raw PCM size")
    }
}
