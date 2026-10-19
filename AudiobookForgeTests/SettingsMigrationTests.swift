import XCTest
@testable import AudiobookForge

/// Phase 2 (plan 5.2): `keepChapterAudioAfterPackaging` ist ein neuer
/// Schlüssel — ein altes settings.json ohne ihn muss verlustfrei
/// dekodieren (neuer Wert = Standard). Kein Feld darf bei einer
/// Erweiterung von AppSettings zurückgesetzt werden.
final class SettingsMigrationTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABF-settings-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// A settings.json from v2 (without the new key) decodes without any
    /// data loss; the new key gets its default (false).
    func testOldSettingsDecodeWithNewDefaults() throws {
        var current = AppSettings()
        current.mp3Quality = 4
        current.aacBitrateKbps = 96
        current.outputBaseFolderPath = "/Users/tester/Audiobooks"
        current.ttsParallelWorkers = 3
        current.autoStartOMLX = true
        current.llmRequestTimeoutSeconds = 120

        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        // Simuliert ein v2-settings.json: der neue Schlüssel fehlt.
        object.removeValue(forKey: "keepChapterAudioAfterPackaging")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: oldData)

        XCTAssertEqual(decoded.keepChapterAudioAfterPackaging, false, "neuer Schlüssel muss den Standard false bekommen")
        XCTAssertEqual(decoded.mp3Quality, 4)
        XCTAssertEqual(decoded.aacBitrateKbps, 96)
        XCTAssertEqual(decoded.outputBaseFolderPath, "/Users/tester/Audiobooks")
        XCTAssertEqual(decoded.ttsParallelWorkers, 3)
        XCTAssertEqual(decoded.autoStartOMLX, true)
        XCTAssertEqual(decoded.llmRequestTimeoutSeconds, 120)
    }

    /// The setting round-trips through the real SettingsStore.
    func testSettingPersistsThroughSettingsStore() throws {
        let fileURL = work.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: fileURL)
        var settings = store.settings
        settings.keepChapterAudioAfterPackaging = true
        store.settings = settings

        let reloaded = SettingsStore(fileURL: fileURL)
        XCTAssertTrue(reloaded.settings.keepChapterAudioAfterPackaging)
    }

    /// A minimal/partial settings.json decodes to defaults instead of
    /// throwing (throwing would wipe the whole configuration in
    /// SettingsStore's fallback).
    func testPartialSettingsDecodeToDefaults() throws {
        let partial = """
        {"mp3Quality": 7, "ttsParallelWorkers": 2}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
        XCTAssertEqual(decoded.mp3Quality, 7)
        XCTAssertEqual(decoded.ttsParallelWorkers, 2)
        XCTAssertEqual(decoded.keepChapterAudioAfterPackaging, false)
        XCTAssertEqual(decoded.aacBitrateKbps, AppSettings().aacBitrateKbps)
        XCTAssertEqual(decoded.outputBaseFolderPath, AppSettings().outputBaseFolderPath)
    }

    /// Unknown keys in a future settings.json don't break decoding either.
    func testUnknownSettingsKeysAreIgnored() throws {
        let json = """
        {"mp3Quality": 5, "futurePhase9Key": "unbekannt"}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.mp3Quality, 5)
    }
}
