import XCTest
@testable import AudiobookForge

/// v4: Phonon engine, per-engine parallelism, Hugging Face access mapping,
/// shared bridge speech plan. No network, no model, no bridge process.
final class V4EngineTests: XCTestCase {
    func testPhononVoiceIDSplitsLanguageAndName() {
        XCTAssertEqual(PhononEngine.split("de/Henrik").language, "de")
        XCTAssertEqual(PhononEngine.split("de/Henrik").name, "Henrik")
        XCTAssertEqual(PhononEngine.split("Henrik").language, "de")
    }

    func testPhononTempoMapsToClampedDurationDelta() {
        XCTAssertEqual(PhononEngine.durationDelta(forSpeed: 1.0), 0, accuracy: 1e-9)
        XCTAssertLessThan(PhononEngine.durationDelta(forSpeed: 1.25), 0)
        XCTAssertGreaterThan(PhononEngine.durationDelta(forSpeed: 0.85), 0)
        XCTAssertEqual(PhononEngine.durationDelta(forSpeed: 3.0), -0.6, accuracy: 1e-9)
        XCTAssertEqual(PhononEngine.durationDelta(forSpeed: 0.5), 0.3, accuracy: 1e-9)
    }

    func testPhononCatalogCoversFourLanguagesWithRanking() {
        let languages = Set(PhononVoice.catalog.map(\.language))
        XCTAssertEqual(languages, ["de", "en", "fr", "es"])
        XCTAssertEqual(PhononVoice.catalog.filter { $0.language == "de" }.count, 13)
        XCTAssertTrue(PhononVoice.catalog.contains { $0.id == "de/Henrik" })
        let featuredGerman = VoiceCatalog.allProfiles.filter { $0.id.engine == .phonon && $0.baseLanguage == "de" && $0.featured }
        XCTAssertEqual(featuredGerman.count, 4, "top two per gender")
    }

    func testPerEngineWorkersFallBackToLegacySettingForOldEngines() {
        var settings = AppSettings()
        settings.ttsParallelWorkers = 1
        XCTAssertEqual(settings.ttsWorkers(for: .kokoro), 1)
        XCTAssertEqual(settings.ttsWorkers(for: .phonon), TTSEngineID.phonon.recommendedWorkers)
        settings.ttsWorkersByEngine["phonon"] = 6
        XCTAssertEqual(settings.ttsWorkers(for: .phonon), 6)
        settings.ttsWorkersByEngine["phonon"] = 99
        XCTAssertEqual(settings.ttsWorkers(for: .phonon), TTSEngineID.phonon.maxWorkers)
    }

    func testPerEngineWorkersSurviveEncoding() throws {
        var settings = AppSettings()
        settings.ttsWorkersByEngine = ["phonon": 5]
        settings.phononVoice = "fr/Noémie"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.ttsWorkersByEngine, ["phonon": 5])
        XCTAssertEqual(decoded.phononVoice, "fr/Noémie")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"ttsParallelWorkers": 3}"#.utf8))
        XCTAssertEqual(old.ttsWorkers(for: .piper), 3)
        let lowOld = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"ttsParallelWorkers": 1}"#.utf8))
        XCTAssertEqual(lowOld.ttsWorkers(for: .kokoro), 2, "v3-Maximal lief mit mind. 2 Workern — Upgrade behält das")
        XCTAssertEqual(lowOld.ttsWorkers(for: .omniVoice), 1)
        XCTAssertEqual(lowOld.ttsWorkers(for: .phonon), TTSEngineID.phonon.recommendedWorkers)
    }

    func testEnergyModesCapWorkers() {
        XCTAssertEqual(PowerMode.maximum.ttsWorkers(userSetting: 6), 6)
        XCTAssertEqual(PowerMode.balanced.ttsWorkers(userSetting: 6), 3)
        XCTAssertEqual(PowerMode.balanced.ttsWorkers(userSetting: 4), 2)
        XCTAssertEqual(PowerMode.balanced.ttsWorkers(userSetting: 1), 1)
        XCTAssertEqual(PowerMode.saver.ttsWorkers(userSetting: 6), 1)
    }

    func testHuggingFaceStatusMapping() {
        XCTAssertEqual(HuggingFaceAccount.accessState(statusCode: 200, hasToken: true), .granted)
        XCTAssertEqual(HuggingFaceAccount.accessState(statusCode: 302, hasToken: true), .granted)
        XCTAssertEqual(HuggingFaceAccount.accessState(statusCode: 403, hasToken: true), .termsRequired)
        XCTAssertEqual(HuggingFaceAccount.accessState(statusCode: 401, hasToken: false), .signedOut)
        XCTAssertEqual(HuggingFaceAccount.accessState(statusCode: 401, hasToken: true), .termsRequired)
        XCTAssertEqual(HuggingFaceAccount.accessState(statusCode: 500, hasToken: true), .unreachable)
    }

    func testDownloadEnvironmentCarriesTokenOnlyAsHFToken() {
        HuggingFaceAccount.tokenOverride = .some("hf_test")
        defer { HuggingFaceAccount.tokenOverride = nil }
        let env = HuggingFaceAccount.processEnvironment(base: ["PATH": "/usr/bin"])
        XCTAssertEqual(env["HF_TOKEN"], "hf_test")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testBridgeSpeechPlanMatchesPausePlanner() {
        let text = "Erster Satz. Zweiter Satz!\n\nNeuer Absatz mit einer Frage?"
        let plan = BridgeSpeechPlan(text: text, determinismKey: "k", settings: AppSettings())
        XCTAssertEqual(plan.segments, PausePlanner.plan(text).map(\.text))
        XCTAssertEqual(plan.pauses_ms.count, plan.segments.count)
    }

    func testPhononEnvironmentPathsAndReadiness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abf-phonon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = PhononEnvironmentManager(root: root)
        XCTAssertFalse(env.isModelReady("de"))
        let dir = env.modelDirectory(for: "de")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "model.q8.gguf"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        XCTAssertTrue(env.isModelReady("de"))
        XCTAssertEqual(env.installedLanguages, ["de"])
        try env.removeModel("de")
        XCTAssertFalse(env.isModelReady("de"))
    }

    func testRerunWritesIntoTheBooksOwnOutputFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abf-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var settings = AppSettings()
        settings.outputBaseFolderPath = base.path
        var book = BookProject(title: "Titel", author: "A", sourceType: .epub, sourceURL: URL(fileURLWithPath: "/dev/null"),
                               chapters: [], outputFormat: .mp3Chapters, voice: "x", speechSpeed: 1)
        let first = OutputPathResolver.resolveOutputDirectory(book: book, settings: settings)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        // Another book with the same title gets its own folder …
        XCTAssertNotEqual(OutputPathResolver.resolveOutputDirectory(book: book, settings: settings), first)
        // … but re-voicing this book reuses its folder.
        book.outputDirectoryURL = first
        XCTAssertEqual(OutputPathResolver.resolveOutputDirectory(book: book, settings: settings), first)
    }
}

final class VoiceCurationTests: XCTestCase {
    func testEveryGalleryLanguageHasCuratedVoices() {
        for language in VoiceCatalog.galleryLanguages {
            XCTAssertFalse(VoiceCatalog.curated(.quality, language: language).isEmpty, language)
            XCTAssertFalse(VoiceCatalog.curated(.speed, language: language).isEmpty, language)
        }
    }

    func testCurationIsShortAndMixesEngines() {
        let list = VoiceCatalog.curated(.quality, language: "de")
        XCTAssertLessThanOrEqual(list.count, 6)
        XCTAssertLessThanOrEqual(Dictionary(grouping: list, by: \.id.engine).values.map(\.count).max() ?? 0, 3)
        let fast = VoiceCatalog.curated(.speed, language: "de")
        XCTAssertEqual(fast.first?.id.engine, .phonon, "Phonon ist die schnellste Engine")
    }

    func testDefaultVoicesForNewLanguages() {
        var settings = AppSettings()
        XCTAssertEqual(settings.defaultVoiceID(forLanguage: "it").engine, .pocketTTS)
        XCTAssertEqual(settings.defaultVoiceID(forLanguage: "fr").engine, .phonon)
        settings.defaultVoicesByLanguage["fr"] = VoiceID(engine: .pocketTTS, voice: "fr/estelle")
        XCTAssertEqual(settings.defaultVoiceID(forLanguage: "fr-FR").voice, "fr/estelle")
    }
}

/// v4: bundled samples stay small and cover the catalog.
final class VoiceSampleBudgetTests: XCTestCase {
    func testSamplesStayWithinBudgetAndResolve() throws {
        let index = VoiceSampleLibrary.index
        XCTAssertGreaterThan(index.count, 150, "Hörproben für (fast) alle Stimmen")
        var total = 0
        for (key, entry) in index {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let id = VoiceID(engine: TTSEngineID(rawValue: parts[0]) ?? .kokoro, voice: parts[1])
            let url = try XCTUnwrap(VoiceSampleLibrary.url(for: id), key)
            total += (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            XCTAssertFalse(entry.text.isEmpty)
        }
        XCTAssertLessThanOrEqual(total, 8 * 1024 * 1024, "Alle Hörproben zusammen höchstens 8 MB")
    }

    func testCatalogSampleTextMatchesBundledSample() {
        guard let profile = VoiceCatalog.allProfiles.first(where: { $0.id.engine == .phonon && $0.baseLanguage == "de" }) else {
            return XCTFail("Phonon-Profil fehlt")
        }
        XCTAssertNotNil(VoiceSampleLibrary.url(for: profile.id, text: profile.sampleText))
        XCTAssertNil(VoiceSampleLibrary.url(for: profile.id, text: "Ein anderer Text."))
    }
}
