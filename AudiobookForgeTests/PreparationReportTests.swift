import XCTest
@testable import AudiobookForge

/// Phase 3 (plan 6.7): the "Vorbereitung prüfen" report — counters per
/// rule with current settings, suspicious chapters flagged.
final class PreparationReportTests: XCTestCase {

    private func chapter(_ title: String, _ text: String) -> Chapter {
        Chapter(title: title, rawText: text, cleanedText: text, order: 0)
    }

    func testCountersReflectCurrentSettings() {
        var settings = AppSettings()
        settings.boxLabelHandling = .remove
        settings.speakHeadingNumbers = false

        let chapters = [
            chapter("Kapitel 1", "▶ Merke.\nDer Uterus liegt anteversiert.\n▪ Erstes Symptom\n1.2 Überschrift im Text"),
            chapter("Kapitel 2", "▶ Definition: Metaplasie ist die Umwandlung. Normal weiter."),
        ]
        let report = PreparationReport.build(chapters: chapters, settings: settings)
        XCTAssertEqual(report.boxLabelOnlyLines, 1)          // "▶ Merke."-Zeile
        XCTAssertEqual(report.boxLabelPrefixes, 1)           // "▶ Definition: …"
        XCTAssertEqual(report.listItems, 1)                  // "▪ Erstes Symptom"
        XCTAssertEqual(report.headingNumbersStripped, 1)     // "1.2 Überschrift"
        XCTAssertEqual(report.miniChapters, 2)                // beide < 800 Zeichen
    }

    func testKeepSettingsChangeTheCounters() {
        var settings = AppSettings()
        settings.boxLabelHandling = .keep
        let text = "▶ Merke.\nWichtiger Hinweis, aber kurz."
        let report = PreparationReport.build(chapters: [chapter("K", text)], settings: settings)
        XCTAssertEqual(report.boxLabelOnlyLines, 0)
        XCTAssertEqual(report.boxLabelPrefixes, 0)
    }

    func testTocSuggestionsAndExclusionsAreCounted() {
        var settings = AppSettings()
        var toc = chapter("Inhaltsverzeichnis", "Kapitel 1 … 12")
        toc.matterKind = .toc
        var forced = chapter("Vorwort", "Liebe Leserin.")
        forced.matterKind = .frontMatter
        forced.includeInNarration = true // Nutzer übersteuert: zählt nicht als Vorschlag
        var excluded = chapter("Anhang", "Tabellen.")
        excluded.includeInNarration = false

        let report = PreparationReport.build(chapters: [toc, forced, excluded], settings: settings)
        XCTAssertEqual(report.tocSuggested, 1, "nur ohne Nutzerübersteuerung")
        XCTAssertEqual(report.excludedByUser, 1)
    }

    func testSuspiciousChaptersListLowerCaseStartsAndMinis() {
        let settings = AppSettings()
        let lower = chapter("Verschoben", "werden auch zu kontralateralen Lymphabflusswegen …")
        let normal = chapter("Normal", String(repeating: "Vollständiger Fließtext mit vielen Zeichen. ", count: 80))
        let report = PreparationReport.build(chapters: [lower, normal], settings: settings)
        XCTAssertEqual(report.lowercaseStartChapters, 1)
        XCTAssertEqual(report.miniChapters, 1)
        XCTAssertEqual(report.suspiciousChapters, ["Verschoben"])
        XCTAssertEqual(report.miniChapters + report.lowercaseStartChapters, 2)
    }
}
