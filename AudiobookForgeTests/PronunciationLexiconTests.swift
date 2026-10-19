import XCTest
@testable import AudiobookForge

/// Phase 3 (plan 6.6): pronunciation lexicon — anatomical abbreviations
/// with context, units, Greek letters, roman numerals, exact terms,
/// user lexicon, idempotency.
final class PronunciationLexiconTests: XCTestCase {

    private func apply(_ text: String, language: String = "de") -> String {
        PronunciationLexicon.apply(text, languageCode: language)
    }

    // MARK: - (b) Anatomical abbreviations with context

    func testAnatomicalAbbreviationsExpandBeforeLowercase() {
        let cases: [(String, String)] = [
            ("M. levator ani unterstützt den Beckenboden.", "Musculus levator ani unterstützt den Beckenboden."),
            ("Die A. ovarica verläuft im Lig. suspensorium ovarii.", "Die Arteria ovarica verläuft im Ligamentum suspensorium ovarii."),
            ("Die V. cava inferior sammelt das Blut.", "Die Vena cava inferior sammelt das Blut."),
            ("Der N. ischiadicus ist der dickste Nerv.", "Der Nervus ischiadicus ist der dickste Nerv."),
            ("Die Mm. intercostales unterstützen die Atmung.", "Die Musculi intercostales unterstützen die Atmung."),
            ("Die Aa. uterinae verlaufen seitlich.", "Die Arteriae uterinae verlaufen seitlich."),
            ("Die Vv. ovaricae drainieren das Ovar.", "Die Venae ovaricae drainieren das Ovar."),
            ("Die Nn. lumbales entspringen aus dem Rückenmark.", "Die Nervi lumbales entspringen aus dem Rückenmark."),
            ("Die Ligg. lata uteri halten die Gebärmutter.", "Die Ligamenta lata uteri halten die Gebärmutter."),
            ("Die Lnn. iliaci sind regionär betroffen.", "Die Lymphonodi iliaci sind regionär betroffen."),
            ("Der R. marginalis zweigt ab.", "Der Ramus marginalis zweigt ab."),
            ("Die Rr. intestinales versorgen den Darm.", "Die Rami intestinales versorgen den Darm."),
            ("Der M. coccygeus wird innerviert.", "Der Musculus coccygeus wird innerviert."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(apply(input), expected, "Fehler bei: \(input)")
        }
    }

    func testAnatomicalAbbreviationsNegativeCases() {
        // Eigenname folgt (Großbuchstabe): KEINE Expansion.
        XCTAssertEqual(apply("M. Müller wurde operiert."), "M. Müller wurde operiert.")
        XCTAssertEqual(apply("Lig. Schmidt arbeitet hier."), "Lig. Schmidt arbeitet hier.")
        // Abkürzung ohne nachfolgendes Wort bleibt.
        XCTAssertEqual(apply("Der betroffene M."), "Der betroffene M.")
        // Keine Abkürzung ohne Punkt: "M levator" (unerwartet im Text) bleibt.
        XCTAssertEqual(apply("Das große M levator ani"), "Das große M levator ani")
    }

    func testAbbreviationInsideWordIsNeverExpanded() {
        XCTAssertEqual(apply("Form., sowie"), "Form., sowie")
    }

    // MARK: - (c) Units

    func testUnitsAreSpelledOut() {
        let cases: [(String, String)] = [
            ("Der Hb beträgt 12 mg/dl.", "Der Hb beträgt 12 Milligramm pro Deziliter."),
            ("Ein Wert von 100 mmHg ist normal.", "Ein Wert von 100 Millimeter Quecksilber ist normal."),
            ("Gabe von 50 µg Levothyroxin.", "Gabe von 50 Mikrogramm Levothyroxin."),
            ("Die Temperatur beträgt 37,5 °C.", "Die Temperatur beträgt 37,5 Grad Celsius."),
            ("Eine Besserung um 20 %.", "Eine Besserung um 20 Prozent."),
            ("Verabreichung von 5000 IE Heparin.", "Verabreichung von 5000 Internationale Einheiten Heparin."),
            ("Glukose von 90 mg/dl im Serum.", "Glukose von 90 Milligramm pro Deziliter im Serum."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(apply(input), expected, "Fehler bei: \(input)")
        }
    }

    // MARK: - (d) Greek letters

    func testGreekLettersAreSpelledOut() {
        let cases: [(String, String)] = [
            ("α-Interferon wird verwendet.", "Alpha-Interferon wird verwendet."),
            ("Die β-Kette ist verändert.", "Die Beta-Kette ist verändert."),
            ("Gamma-GT (γ-GT) ist erhöht.", "Gamma-GT (Gamma-GT) ist erhöht."),
            ("Der δ-Rezeptor vermittelt Schmerz.", "Der Delta-Rezeptor vermittelt Schmerz."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(apply(input), expected, "Fehler bei: \(input)")
        }
    }

    // MARK: - (e) Roman numerals in context

    func testRomanNumeralsInContextAreSpelled() {
        let cases: [(String, String)] = [
            ("Typ II Fraktur", "Typ zwei Fraktur"),
            ("Typus III der Erkrankung", "Typus drei der Erkrankung"),
            ("Grad IV hämorrhagien", "Grad vier hämorrhagien"),
            ("Stadium II der Erkrankung", "Stadium zwei der Erkrankung"),
            ("Klasse III nach NYHA", "Klasse drei nach NYHA"),
            ("Gruppe I der Läsionen", "Gruppe eins der Läsionen"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(apply(input), expected, "Fehler bei: \(input)")
        }
        // Außerhalb des Kontexts bleibt römische Zahlschrift stehen.
        XCTAssertEqual(apply("Ludwig II. baute Neuschwanstein."), "Ludwig II. baute Neuschwanstein.")
    }

    // MARK: - (a) Exact rules (built-in catalog)

    func testExactRulesApplyWithWordBoundaries() {
        XCTAssertEqual(apply("Z. n. Appendektomie 2019."), "Zustand nach Appendektomie 2019.")
        XCTAssertEqual(apply("V. a. eine Adnexitis."), "Verdacht auf eine Adnexitis.")
        XCTAssertEqual(apply("Die Gabe erfolgt p.o."), "Die Gabe erfolgt per os")
        XCTAssertEqual(apply("Der Befund ist o. B."), "Der Befund ist ohne Befund")
        // Wortgrenzen: "RF" im Inneren eines Worts bleibt.
        XCTAssertEqual(apply("Die Karbonfasern (CF) sind stabil."), "Die Karbonfasern (CF) sind stabil.")
    }

    func testEnglishCatalogIsUsedForEnglish() {
        XCTAssertEqual(apply("e.g. in cardiac patients", language: "en"), "for example in cardiac patients")
        XCTAssertEqual(apply("i.e. the apex", language: "en"), "that is the apex")
    }

    // MARK: - Idempotency

    func testApplyingTwiceEqualsOnce() {
        let samples = [
            "M. levator ani, Typ II, 12 mg/dl, α-Rezeptor, 37 °C, 5000 IE, V. a. Tumor",
            "Die A. femoralis und die V. saphena verlaufen parallel; Typ III nach Figo.",
        ]
        for sample in samples {
            let once = apply(sample)
            let twice = apply(once)
            XCTAssertEqual(once, twice, "Lexikon muss idempotent sein: \(sample)")
        }
    }

    // MARK: - JSON validity + user lexicon

    func testBundledCatalogsAreValidJSON() throws {
        for name in ["lexicon_de_med", "lexicon_en_med"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json"), "\(name) fehlt im Bundle")
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(PronunciationLexicon.Catalog.self, from: data)
            XCTAssertNotNil(catalog.exact)
            // Keine Zyklen: eine Ersetzung darf sich nicht selbst als Quelle eintragen.
            for rule in catalog.exact ?? [] {
                XCTAssertFalse(rule.to.contains(rule.from), "Zyklus-Verdacht in \(name): \(rule.from)")
            }
        }
    }

    func testUserLexiconWinsOverBuiltIn() throws {
        let url = PronunciationLexicon.userLexiconURL()
        let original = try? Data(contentsOf: url)
        defer {
            if let original { try? original.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
        let payload = """
        {"exact": [{"from": "Appendix", "to": "Anhang"}]}
        """
        try Data(payload.utf8).write(to: url)
        // Nutzerregel greift, eingebaute Regeln weiterhin.
        XCTAssertTrue(apply("Die Appendix wird entfernt.").hasPrefix("Die Anhang"))
        XCTAssertEqual(apply("V. a. Appendizitis."), "Verdacht auf Appendizitis.")
    }

    // MARK: - No-ops

    func testNormalProseIsUntouched() {
        let prose = "Die Patientin stellte sich mit Unterleibsschmerzen vor. Die Anamnese war unauffällig, die Untersuchung ergab einen druckschmerzhaften Unterbauch."
        XCTAssertEqual(apply(prose), prose)
    }
}
