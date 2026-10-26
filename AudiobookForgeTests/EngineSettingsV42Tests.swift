import XCTest
@testable import AudiobookForge

/// v4.2: expression sliders, Thorsten styles, install/remove inventory,
/// Hugging Face cache cleanup, fallback voice.
final class EngineSettingsV42Tests: XCTestCase {

    // MARK: Expression

    func testDefaultSitsInTheMiddleOfTheSlider() {
        let range = ExpressionDefaults.temperatureRange
        let standard = ExpressionDefaults.temperature
        XCTAssertEqual(ExpressionDefaults.position(of: standard, range: range, standard: standard), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ExpressionDefaults.value(atPosition: 0, range: range, standard: standard), range.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(ExpressionDefaults.value(atPosition: 1, range: range, standard: standard), range.upperBound, accuracy: 1e-9)
        for position in stride(from: 0.0, through: 1.0, by: 0.1) {
            let value = ExpressionDefaults.value(atPosition: position, range: range, standard: standard)
            XCTAssertEqual(ExpressionDefaults.position(of: value, range: range, standard: standard), position, accuracy: 1e-9)
        }
        let piper = ExpressionDefaults.piperNoiseScaleRange
        XCTAssertEqual(ExpressionDefaults.position(of: ExpressionDefaults.piperNoiseScale, range: piper, standard: ExpressionDefaults.piperNoiseScale), 0.5, accuracy: 1e-9)
    }

    func testPiperRhythmFollowsProsodyAtTheModelsRatio() {
        XCTAssertEqual(ExpressionDefaults.piperNoiseW(forNoiseScale: 0.667), 0.8, accuracy: 0.001)
        XCTAssertEqual(ExpressionDefaults.piperNoiseW(forNoiseScale: 0.3335), 0.4, accuracy: 0.001)
    }

    func testPhononLeavesTheNeuralEngineOnlyForANonDefaultTemperature() {
        XCTAssertTrue(PhononEngine.usesNeuralEngine(profile: .saver, speed: 1, temperature: 0.3, neuralReady: true))
        XCTAssertFalse(PhononEngine.usesNeuralEngine(profile: .saver, speed: 1, temperature: 0.5, neuralReady: true))
        XCTAssertFalse(PhononEngine.usesNeuralEngine(profile: .balanced, speed: 1, temperature: 0.3, neuralReady: true))
    }

    func testOldSettingsGetTheDefaultExpression() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.phononTemperature, 0.3)
        XCTAssertEqual(settings.pocketTemperature, 0.3)
        XCTAssertEqual(settings.expression(for: .piper), 0.667)
        XCTAssertNil(settings.expression(for: .kokoro))
        var changed = settings
        changed.pocketTemperature = 0.55
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(roundTrip.pocketTemperature, 0.55)
    }

    // MARK: Thorsten Emotional

    func testThorstenStylesShareOneModelAndPickTheirSpeaker() throws {
        let id = "de_DE-thorsten_emotional-medium#whisper"
        XCTAssertEqual(PiperEnvironmentManager.baseVoiceID(id), "de_DE-thorsten_emotional-medium")
        XCTAssertEqual(PiperEnvironmentManager.style(of: id), "whisper")
        XCTAssertNil(PiperEnvironmentManager.style(of: "de_DE-thorsten-medium"))
        XCTAssertEqual(PiperVoiceCatalog.voice(id: id)?.id, "de_DE-thorsten_emotional-medium")
        let config = Data(#"{"speaker_id_map": {"amused": 0, "neutral": 4, "whisper": 7}}"#.utf8)
        XCTAssertEqual(PiperEnvironmentManager.speakerID(style: "whisper", config: config), 7)
        XCTAssertEqual(PiperEnvironmentManager.speakerID(style: "neutral", config: config), 4)
        XCTAssertNil(PiperEnvironmentManager.speakerID(style: "drunk", config: config))
    }

    func testGalleryOffersFiveThorstenStylesAndKeepsTheOldVoice() {
        let styles = VoiceCatalog.allProfiles.filter { $0.id.voice.hasPrefix("de_DE-thorsten_emotional-medium") }
        XCTAssertEqual(styles.count, 5)
        XCTAssertNotNil(VoiceCatalog.profile(for: VoiceID(engine: .piper, voice: "de_DE-thorsten_emotional-medium")),
                        "Books with the old id (speaker 0, amused) keep a profile")
        let settings = AppSettings()
        let required = Set(styles.flatMap { EngineInventory.requiredComponentIDs(for: $0.id, settings: settings) })
        XCTAssertEqual(required, ["piper.runtime", "piper.voice.de_DE-thorsten_emotional-medium"], "one download for all styles")
    }

    // MARK: Install inventory

    func testEachVoiceNeedsItsRuntimeAndModel() {
        var settings = AppSettings()
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: VoiceID(engine: .phonon, voice: "fr/Lilou"), settings: settings),
                       ["phonon.runtime", "phonon.model.fr"])
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: VoiceID(engine: .pocketTTS, voice: "it/marius"), settings: settings),
                       ["pocket.runtime", "pocket.model.it"])
        settings.pocketHighQuality = true
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: VoiceID(engine: .pocketTTS, voice: "it/marius"), settings: settings),
                       ["pocket.runtime", "pocket.model.it", "pocket.model.it.24l"])
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: VoiceID(engine: .kokoroGerman, voice: "victoria"), settings: settings),
                       ["mlx.runtime", "kokoroGerman.victoria"])
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: VoiceID(engine: .appleSystem, voice: "auto"), settings: settings), [])
    }

    func testEveryCatalogVoiceMapsToComponentsOfItsEngine() {
        let settings = AppSettings()
        for profile in VoiceCatalog.allProfiles where profile.id.engine != .appleSystem {
            let ids = EngineInventory.requiredComponentIDs(for: profile.id, settings: settings)
            XCTAssertFalse(ids.isEmpty, "\(profile.id)")
        }
    }

    func testPythonPackageVersionIsReadFromDistInfo() throws {
        let venv = FileManager.default.temporaryDirectory.appendingPathComponent("venv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: venv) }
        let site = venv.appendingPathComponent(".venv/lib/python3.11/site-packages/piper_tts-1.3.0.dist-info")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        XCTAssertEqual(EngineInventory.pythonPackageVersion("piper_tts", venv: venv), "1.3.0")
        XCTAssertEqual(EngineInventory.pythonPackageVersion("piper-tts", venv: venv), "1.3.0")
        XCTAssertNil(EngineInventory.pythonPackageVersion("ptts", venv: venv))
    }

    // MARK: Fallback voice

    func testFallbackVoiceIsTheEngineAndItsVoice() {
        var settings = AppSettings()
        settings.setFallbackVoice(VoiceID(engine: .pocketTTS, voice: "fr/estelle"))
        XCTAssertEqual(settings.ttsEngine, .pocketTTS)
        XCTAssertEqual(settings.fallbackVoice, VoiceID(engine: .pocketTTS, voice: "fr/estelle"))
        settings.setFallbackVoice(VoiceID(engine: .phonon, voice: "de/Nele"))
        XCTAssertEqual(settings.fallbackVoice, VoiceID(engine: .phonon, voice: "de/Nele"))
        XCTAssertEqual(settings.pocketVoice, "fr/estelle", "the other engine's voice stays")
    }

    // MARK: Hugging Face cache cleanup

    /// hub/blobs/<shard>/<hash> ← models--org--x/blobs/<h> ← snapshots/rev/…
    private func makeHub() throws -> (hub: URL, de: URL, shared: URL) {
        let fm = FileManager.default
        let hub = fm.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)", isDirectory: true)
        for (shard, hash, bytes) in [("aa", "hash-de", 1000), ("bb", "hash-shared", 500)] {
            try fm.createDirectory(at: hub.appendingPathComponent("blobs/\(shard)"), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: hub.appendingPathComponent("blobs/\(shard)/\(hash)"))
        }
        func repo(_ name: String, files: [(String, String, String)]) throws {
            let base = hub.appendingPathComponent("models--org--\(name)")
            try fm.createDirectory(at: base.appendingPathComponent("blobs"), withIntermediateDirectories: true)
            for (path, blob, shardHash) in files {
                let blobLink = base.appendingPathComponent("blobs/\(blob)")
                if !fm.fileExists(atPath: blobLink.path) {
                    try fm.createSymbolicLink(atPath: blobLink.path, withDestinationPath: "../../blobs/\(shardHash)")
                }
                let file = base.appendingPathComponent("snapshots/rev/\(path)")
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let depth = path.split(separator: "/").count + 1
                try fm.createSymbolicLink(atPath: file.path, withDestinationPath: String(repeating: "../", count: depth) + "blobs/\(blob)")
            }
        }
        try repo("pocket", files: [("languages/de/model.safetensors", "b-de", "aa/hash-de"), ("languages/en/tokenizer.model", "b-sh", "bb/hash-shared")])
        try repo("other", files: [("tokenizer.model", "b-sh", "bb/hash-shared")])
        return (hub, hub.appendingPathComponent("models--org--pocket/snapshots/rev/languages/de"), hub.appendingPathComponent("blobs/bb/hash-shared"))
    }

    func testRemovingASnapshotFolderFreesItsDataButKeepsSharedData() throws {
        let (hub, de, shared) = try makeHub()
        defer { try? FileManager.default.removeItem(at: hub) }
        XCTAssertEqual(HFCacheJanitor.resolvedSize(of: de), 1000)
        let freed = try HFCacheJanitor.remove([de], hubRoot: hub)
        XCTAssertEqual(freed, 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hub.appendingPathComponent("blobs/aa/hash-de").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: hub.appendingPathComponent("models--org--pocket/blobs/b-de").path))
    }

    func testRemovingARepoKeepsDataAnotherRepoStillUses() throws {
        let (hub, _, shared) = try makeHub()
        defer { try? FileManager.default.removeItem(at: hub) }
        try HFCacheJanitor.removeRepo("org/pocket", hubRoot: hub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hub.appendingPathComponent("models--org--pocket").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path), "still used by org/other")
        try HFCacheJanitor.removeRepo("org/other", hubRoot: hub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
    }
}

final class NetworkPolicyTests: XCTestCase {
    func testDownloadsGiveUpOnAStalledConnectionAndRetry() {
        let env = NetworkPolicy.childProcessEnvironment
        XCTAssertEqual(env["HF_HUB_DOWNLOAD_TIMEOUT"], "30")
        XCTAssertEqual(env["PIP_DEFAULT_TIMEOUT"], "30")
        XCTAssertNotNil(env["PIP_RETRIES"])
        XCTAssertEqual(NetworkPolicy.attempts, 3)
    }

    func testMissingTermsAndCancellationAreNotRetried() {
        XCTAssertFalse(NetworkPolicy.isRetryable(CancellationError()))
        XCTAssertFalse(NetworkPolicy.isRetryable(PhononEnvironmentManager.InstallError.termsRequired("gradium/phonon-40m-de")))
        XCTAssertTrue(NetworkPolicy.isRetryable(URLError(.timedOut)))
    }
}

final class PhononEnglish31mTests: XCTestCase {
    func testEnglishCanUseTheFree31mModel() {
        XCTAssertEqual(PhononEnvironmentManager.modelKey(language: "en", english31m: true), "en-31m")
        XCTAssertEqual(PhononEnvironmentManager.modelKey(language: "en", english31m: false), "en")
        XCTAssertEqual(PhononEnvironmentManager.modelKey(language: "de", english31m: true), "de", "only English has a 31m model")
        XCTAssertEqual(PhononEnvironmentManager.repo(for: "en-31m"), "gradium/phonon-31m-en")
        XCTAssertEqual(PhononEnvironmentManager.repo(for: "fr"), "gradium/phonon-40m-fr")
        XCTAssertFalse(PhononEnvironmentManager.isGated("en-31m"))
        XCTAssertTrue(PhononEnvironmentManager.isGated("en"))
        XCTAssertEqual(PhononEnvironmentManager.language(ofModel: "en-31m"), "en")
    }

    func testTheChosenModelIsWhatAVoiceNeeds() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.phononEnglish31m)
        let voice = VoiceID(engine: .phonon, voice: "en/Zoey")
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: voice, settings: settings), ["phonon.runtime", "phonon.model.en"])
        settings.phononEnglish31m = true
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: voice, settings: settings), ["phonon.runtime", "phonon.model.en-31m"])
        XCTAssertEqual(EngineInventory.requiredComponentIDs(for: VoiceID(engine: .phonon, voice: "de/Nele"), settings: settings),
                       ["phonon.runtime", "phonon.model.de"])
    }
}

final class ScriptRunnerSignalTests: XCTestCase {
    /// A helper that crashes (e.g. SIGILL from CPU instructions an older Mac
    /// lacks) must not look like its own exit code 4.
    func testACrashIsReportedAsNegativeSignal() async throws {
        let crashed = try await ScriptRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -ILL $$"]) { _ in }
        XCTAssertEqual(crashed, -SIGILL)
        let exited = try await ScriptRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 4"]) { _ in }
        XCTAssertEqual(exited, 4)
    }
}

final class HelperBinaryTests: XCTestCase {
    /// The Core ML exporter must run on every Apple silicon Mac: no CSSC
    /// instructions (M4+ only), which `target-cpu=native` emits on newer Macs.
    func testCoreMLExporterRunsOnM1() throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/phonon-coreml-export")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: helper.path), "Helper not in the checkout")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/otool"), "otool missing")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-tv", helper.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let cssc: Set<String> = ["abs", "cnt", "ctz", "smax", "smin", "umax", "umin"]
        var found = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if fields.count > 1, cssc.contains(String(fields[1])) { found.insert(String(fields[1])) }
        }
        XCTAssertTrue(found.isEmpty, "M4-only instructions in the exporter: \(found.sorted()) — rebuild with RUSTFLAGS=\"-C target-cpu=apple-m1\"")
    }
}

final class ChapterOutlineGroupTests: XCTestCase {
    private func chapters(_ count: Int, groups: [String?] = []) -> [Chapter] {
        (0..<count).map { index in
            var chapter = Chapter(title: "K\(index)", rawText: "", cleanedText: "", order: index)
            if !groups.isEmpty { chapter.groupTitle = groups[index] }
            return chapter
        }
    }

    func testShortFlatOutlinesStayOneList() {
        let groups = ChapterOutlineGroup.make(chapters(33))
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].title)
    }

    func testLongFlatOutlinesComeInBlocksOf25() {
        let groups = ChapterOutlineGroup.make(chapters(943))
        XCTAssertEqual(groups.count, 38)
        XCTAssertEqual(groups.first?.range, 0..<25)
        XCTAssertEqual(groups.last?.range, 925..<943)
        XCTAssertEqual(groups.map(\.range.count).reduce(0, +), 943)
    }

    func testTheBooksOwnGroupsAreKept() {
        let groups = ChapterOutlineGroup.make(chapters(5, groups: [nil, "A", "A", "B", "B"]))
        XCTAssertEqual(groups.map(\.title), [nil, "A", "B"])
        XCTAssertEqual(groups.map(\.range), [0..<1, 1..<3, 3..<5])
    }
}
