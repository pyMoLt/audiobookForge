import XCTest
@testable import AudiobookForge

/// OmniVoice integration (user decision 2026-10-18: "OmniVoice kann man
/// einbauen"): engine metadata, settings migration, language mapping,
/// bridge script syntax.
final class OmniVoiceEngineTests: XCTestCase {
    func testEngineIDRoundTrip() throws {
        XCTAssertEqual(try JSONDecoder().decode(TTSEngineID.self, from: JSONEncoder().encode(TTSEngineID.omniVoice)), .omniVoice)
    }

    func testSettingsRoundTripAndLegacyDefault() throws {
        var settings = AppSettings()
        settings.omniVoiceSteps = 16
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.omniVoiceSteps, 16)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"ttsEngine\": \"kokoro\"}".utf8))
        XCTAssertEqual(legacy.omniVoiceSteps, 32, "Alte settings.json bekommt den Modellstandard")
    }

    func testLanguageTagMapping() {
        XCTAssertEqual(OmniVoiceEngine.languageTag(for: "de-AT"), "de")
        XCTAssertEqual(OmniVoiceEngine.languageTag(for: "en-US"), "en")
        XCTAssertEqual(OmniVoiceEngine.languageTag(for: nil), "de")
        XCTAssertEqual(OmniVoiceEngine.languageTag(for: "x"), "x", "Unbekannte kurze Tags gehen unverändert durch")
    }

    func testCatalogContainsOmniVoiceAndQwen3MapsToIt() throws {
        let omni = VoiceCatalog.allProfiles.filter { $0.id.engine == .omniVoice }
        XCTAssertEqual(omni.count, 1)
        XCTAssertEqual(omni.first?.id.voice, "default")
        XCTAssertTrue(omni.first!.featured, "OmniVoice ist nach dem Nutzertest eine empfohlene Stimme")

        // Qwen3-TTS was removed (v3.2): books/settings that still say
        // "qwen3" continue on OmniVoice, the remaining cloning engine.
        let decoded = try JSONDecoder().decode([TTSEngineID].self, from: Data(#"["qwen3","omniVoice","unknownEngine"]"#.utf8))
        XCTAssertEqual(decoded, [.omniVoice, .omniVoice, .kokoro])
        // The cloning engine is tagged so the gallery can rely on it.
        XCTAssertTrue(VoiceCatalog.profile(for: VoiceID(engine: .omniVoice, voice: "default"))!.tags.contains("Klon-fähig"))
    }

    func testBridgeScriptShipsAndCompiles() throws {
        let candidates = [
            Bundle.main.url(forResource: "omnivoice_bridge", withExtension: "py", subdirectory: "Bridge"),
            Bundle.main.url(forResource: "omnivoice_bridge", withExtension: "py"),
            Bundle(for: OmniVoiceEngineTests.self).url(forResource: "omnivoice_bridge", withExtension: "py", subdirectory: "Bridge"),
        ]
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudiobookForge/Resources/Bridge/omnivoice_bridge.py")
        let url = candidates.compactMap({ $0 }).first ?? sourceURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Bridge-Skript existiert")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import ast, sys; ast.parse(open(sys.argv[1]).read())", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Bridge-Skript hat valides Python")
    }

    func testAppleSystemVoicesEngine() async {
        // v3.2: macOS system voices as an engine — reachable through the
        // factory, "auto" always offered, ready whenever any de/en voice is
        // installed (every Mac ships some).
        let engine = TTSEngineFactory.engine(for: .appleSystem, settings: AppSettings())
        XCTAssertEqual(engine.id, .appleSystem)
        XCTAssertEqual(engine.availableVoices().first?.id, AppleSpeechEngine.automaticVoice)
        XCTAssertEqual(AppSettings().defaultVoice(for: .appleSystem), AppleSpeechEngine.automaticVoice)
        let installed = AppleSpeechEngine.installedVoices()
        let ready = await engine.isReady()
        XCTAssertEqual(ready, !installed.isEmpty)
        // Best quality first.
        let ranks = installed.map(\.quality.rawValue)
        XCTAssertEqual(ranks, ranks.sorted(by: >))
    }
}
