import XCTest
@testable import AudiobookForge

/// Phase 3 (plan 6.4): bullets become spoken sentences, numbered
/// headings lose their spoken number (default), stray bullets vanish —
/// table-like content is never destroyed.
final class ListAndNumberingTests: XCTestCase {

    private func apply(_ text: String, speakNumbers: Bool = false) -> String {
        ListNumberingFilter.apply(text, speakHeadingNumbers: speakNumbers).text
    }

    func testBulletItemsBecomeSentences() {
        let text = "Folgende Befunde sind typisch:\n▪ Pathologie der Ovarien\n• Klinik der extrauterinen Gravidität\n● Therapie der Endometriose"
        let shaped = apply(text)
        XCTAssertTrue(shaped.contains("Pathologie der Ovarien."))
        XCTAssertTrue(shaped.contains("Klinik der extrauterinen Gravidität."))
        XCTAssertTrue(shaped.contains("Therapie der Endometriose."))
        XCTAssertFalse(shaped.contains("▪"))
        XCTAssertFalse(shaped.contains("•"))
    }

    func testBulletItemKeepsExistingPunctuation() {
        XCTAssertEqual(apply("▸ Was tun? Hypothyreose ausschließen."), "Was tun? Hypothyreose ausschließen.")
    }

    func testStrayBulletsMidTextAreRemoved() {
        XCTAssertEqual(apply("Uterus• mit Myometrium"), "Uterus mit Myometrium")
    }

    func testNumberedHeadingLosesItsNumberByDefault() {
        XCTAssertEqual(apply("1.2 Therapie des Zervixkarzinoms"), "Therapie des Zervixkarzinoms")
        XCTAssertEqual(apply("12 Einführung in die Anatomie"), "Einführung in die Anatomie")
    }

    func testSpeakHeadingNumbersKeepsTheNumber() {
        XCTAssertEqual(apply("1.2 Therapie", speakNumbers: true), "1.2 Therapie")
    }

    func testTableLikeProseIsNotDestroyed() {
        // Fließtext mit Nummern bleibt Text (Negativfall):
        let prose = "1. Therapie: Zunächst erfolgt die medikamentöse Einstellung.\n2. Kontrolle: Nach vier Wochen wird kontrolliert."
        XCTAssertEqual(apply(prose), prose, "Zeilen mit Nummer UND Satzzeichen sind Fließtext, keine Überschrift")
    }

    func testCleanedTitleStripsNumbering() {
        XCTAssertEqual(ListNumberingFilter.cleanedTitle("1.2 Therapie"), "Therapie")
        // Buchstaben-Nummerierung ("A.3.1") ist nicht Teil des Musters und bleibt stehen.
        XCTAssertEqual(ListNumberingFilter.cleanedTitle("A.3.1 Verlauf"), "A.3.1 Verlauf")
        XCTAssertEqual(ListNumberingFilter.cleanedTitle("Einführung ohne Nummer"), "Einführung ohne Nummer")
        // Datumsangaben bleiben unangetastet ("3." ohne weitere Ziffern ist keine Kapitelnummerierung).
        XCTAssertEqual(ListNumberingFilter.cleanedTitle("3. Oktober 2026"), "3. Oktober 2026")
    }

    func testReportCounters() {
        let text = "Einleitung\n▪ Erstes Symptom\nZweitens• ohne Leerraum"
        let (_, report) = ListNumberingFilter.apply(text, speakHeadingNumbers: false)
        XCTAssertEqual(report.listItems, 1)
        XCTAssertEqual(report.strayBulletsRemoved, 1)
    }

    func testSettingsDefaultAndMigration() throws {
        XCTAssertEqual(AppSettings().speakHeadingNumbers, false)
        let json = """
        {"boxLabelHandling": "spoken"}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.speakHeadingNumbers, false)
        XCTAssertEqual(decoded.boxLabelHandling, .spoken)
    }
}
