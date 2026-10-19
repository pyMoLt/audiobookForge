import XCTest
@testable import AudiobookForge

/// Phase 3 (plan 6.1): box labels ("▶ Merke.", "Definition:", "Klinischer
/// Fall") must disappear from narration (default), stay when kept, and be
/// spoken once per box in `.spoken` — without ever touching the word
/// "merke" inside a sentence.
final class BoxLabelFilterTests: XCTestCase {

    private func apply(_ text: String, _ handling: BoxLabelHandling) -> String {
        BoxLabelFilter.apply(text, handling: handling).text
    }

    // MARK: - Label-only lines (three real-world variants per label)

    func testLabelOnlyLineVariantsAreRemoved() {
        let variants = [
            "▶ Merke.",
            "▶ Merke",
            "Merke:",
            "▷ Definition.",
            "Definition:",
            "• Definition",
            "► Klinischer Fall.",
            "Klinischer Fall:",
            "▶ Synonym.",
            "Synonym:",
            "▶ Cave",
            "▶ Praxistipp:",
        ]
        for variant in variants {
            let shaped = apply("Vorher.\n\(variant)\nDer Uterus liegt anteversiert.", .remove)
            XCTAssertFalse(shaped.contains(variant.trimmingCharacters(in: .whitespaces)), "Variant '\(variant)' blieb stehen: \(shaped)")
            XCTAssertTrue(shaped.contains("Vorher."))
            XCTAssertTrue(shaped.contains("Der Uterus liegt anteversiert."))
        }
    }

    func testEnglishLabelsAreCovered() {
        XCTAssertEqual(apply("Key point: The uterus is anteflexed.", .remove), "The uterus is anteflexed.")
        XCTAssertEqual(apply("▶ Note. Check the dosage.", .remove), "Check the dosage.")
    }

    // MARK: - Prefix stripping keeps the box text

    func testLabelWithTextOnSameLineStripsOnlyPrefix() {
        let shaped = apply("▶ Merke. Der M. levator ani unterstützt die Beckenbodenmuskulatur.", .remove)
        XCTAssertEqual(shaped, "Der M. levator ani unterstützt die Beckenbodenmuskulatur.")
        let shapedColon = apply("Definition: Metaplasie ist die Umwandlung eines Epithels.", .remove)
        XCTAssertEqual(shapedColon, "Metaplasie ist die Umwandlung eines Epithels.")
    }

    // MARK: - Negatives: words inside sentences stay

    func testWordInsideSentenceIsNeverTouched() {
        let sentence = "Man merke sich den Unterschied zwischen Metaplasie und Dysplasie."
        XCTAssertEqual(apply(sentence, .remove), sentence)
        XCTAssertEqual(apply("Eine Definition enthält das Wesentliche.", .remove), "Eine Definition enthält das Wesentliche.")
        XCTAssertEqual(apply("Merkeintrag ohne Trennzeichen bleibt stehen.", .remove), "Merkeintrag ohne Trennzeichen bleibt stehen.")
    }

    func testKeepReturnsOriginal() {
        let text = "▶ Merke.\nDer Uterus liegt anteversiert.\n▶ Definition: Metaplasie."
        XCTAssertEqual(apply(text, .keep), text)
        let report = BoxLabelFilter.apply(text, handling: .keep).report
        XCTAssertEqual(report.removedLabelLines, 0)
        XCTAssertEqual(report.strippedPrefixes, 0)
    }

    func testSpokenReadsLabelOncePerBox() {
        let shaped = apply("▶ Merke.\nDer Uterus liegt anteversiert.", .spoken)
        XCTAssertEqual(shaped, "Merke:\nDer Uterus liegt anteversiert.")
        let inline = apply("▶ Definition: Metaplasie ist die Umwandlung.", .spoken)
        XCTAssertEqual(inline, "Definition: Metaplasie ist die Umwandlung.")
    }

    // MARK: - Report counters

    func testReportCountsRemovalsAndStrips() {
        let text = "▶ Merke.\n▶ Merke. Text folgt.\nNormaler Absatz.\nDefinition: Erklärung."
        let (_, report) = BoxLabelFilter.apply(text, handling: .remove)
        XCTAssertEqual(report.removedLabelLines, 1)
        XCTAssertEqual(report.strippedPrefixes, 2)
    }

    // MARK: - Settings migration

    func testSettingsDefaultAndMigration() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.boxLabelHandling, .remove, "Standard muss .remove sein")

        // Altes settings.json ohne den Schlüssel: Default, kein Datenverlust.
        let json = """
        {"ttsParallelWorkers": 3, "keepChapterAudioAfterPackaging": true}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.boxLabelHandling, .remove)
        XCTAssertEqual(decoded.ttsParallelWorkers, 3)
        XCTAssertEqual(decoded.keepChapterAudioAfterPackaging, true)

        // Explizit gespeicherter Wert bleibt erhalten.
        let explicit = try JSONEncoder().encode(["boxLabelHandling": "spoken"] as [String: String])
        let reencoded = try JSONDecoder().decode(AppSettings.self, from: explicit)
        XCTAssertEqual(reencoded.boxLabelHandling, .spoken)
    }
}
