import XCTest
@testable import AudiobookForge

/// Plan 8.4 — pause planning: segment kinds, lengths, deterministic jitter,
/// bridge payload.
final class PausePlanTests: XCTestCase {
    private func settings(
        sentence: Int = 0,
        paragraph: Int = 450,
        heading: Int = 800,
        listItem: Int = 250,
        figure: Int = 500,
        leadIn: Int = 600,
        tail: Int = 900,
        jitter: Int = 0
    ) -> AppSettings {
        var s = AppSettings()
        s.sentencePauseMs = sentence
        s.paragraphPauseMs = paragraph
        s.headingPauseMs = heading
        s.listItemPauseMs = listItem
        s.figurePauseMs = figure
        s.chapterLeadInMs = leadIn
        s.chapterTailMs = tail
        s.pauseJitterPercent = jitter
        return s
    }

    func testSegmentKindsFromTextStructure() {
        let text = """
        Einleitung mit einem Satz.

        Erster Absatz. Mit zwei Sätzen.

        • Erster Listenpunkt.
        • Zweiter Listenpunkt.

        Abbildung: Die Zelle im Überblick mit allen Organellen.

        2.3 Therapieoptionen

        Schlussabsatz mit einem Satz.
        """
        let segments = PausePlanner.plan(text)
        // Note: the two bullet lines share one paragraph block, so the
        // list pause lands on the LAST bullet of the block (the earlier
        // one keeps the sentence kind — engine-natural gap).
        XCTAssertEqual(segments.map(\.kind), [
            .paragraphEnd,             // Einleitung
            .sentence, .paragraphEnd, // zwei Sätze
            .sentence, .listItem,     // zwei Listenpunkte (Block)
            .figure,                  // Bildbeschreibung
            .heading,                 // Überschrift
            .paragraphEnd,            // Schluss
        ])
        XCTAssertEqual(segments[1].text.hasPrefix("Erster Absatz"), true)
    }

    func testPauseValuesPerKind() {
        let s = settings()
        XCTAssertEqual(PausePlanner.basePauseMs(kind: .sentence, settings: s), 0)
        XCTAssertEqual(PausePlanner.basePauseMs(kind: .paragraphEnd, settings: s), 450)
        XCTAssertEqual(PausePlanner.basePauseMs(kind: .heading, settings: s), 800)
        XCTAssertEqual(PausePlanner.basePauseMs(kind: .listItem, settings: s), 250)
        XCTAssertEqual(PausePlanner.basePauseMs(kind: .figure, settings: s), 500)
    }

    func testPausePlanSumsWithoutJitter() {
        let s = settings()
        let text = "Erster Satz. Zweiter Satz.\n\nÜberschrift\n\nLetzter Satz."
        let plan = PausePlanner.pausePlan(for: text, determinismKey: "chapter-1", settings: s)
        XCTAssertEqual(plan.leadInMs, 600)
        XCTAssertEqual(plan.tailMs, 900)
        XCTAssertEqual(plan.pauseAfterMs, [0, 450, 800, 450])
        XCTAssertEqual(PausePlanner.containsSilence(plan), true)
    }

    func testZeroSettingsProduceNoSilence() {
        let s = settings(sentence: 0, paragraph: 0, heading: 0, listItem: 0, figure: 0, leadIn: 0, tail: 0)
        let plan = PausePlanner.pausePlan(for: "Ein Satz. Noch einer.", determinismKey: "chapter-1", settings: s)
        XCTAssertEqual(plan.pauseAfterMs, [0, 0])
        XCTAssertEqual(PausePlanner.containsSilence(plan), false, "Engines überspringen die Pausendatei komplett")
    }

    func testJitterIsDeterministicAndBounded() {
        let s = settings(paragraph: 450, jitter: 10)
        let first = PausePlanner.jitteredPauseMs(kind: .paragraphEnd, determinismKey: "book/chapter-0001.m4a", segmentIndex: 3, settings: s)
        let again = PausePlanner.jitteredPauseMs(kind: .paragraphEnd, determinismKey: "book/chapter-0001.m4a", segmentIndex: 3, settings: s)
        XCTAssertEqual(first, again, "Regenerierte Kapitel klingen identisch")
        XCTAssertGreaterThanOrEqual(first, 405)
        XCTAssertLessThanOrEqual(first, 495)

        // Zero base stays zero — engine-natural gaps are never jittered.
        XCTAssertEqual(PausePlanner.jitteredPauseMs(kind: .sentence, determinismKey: "x", segmentIndex: 0, settings: s), 0)
    }

    func testJitterVariesAcrossSegments() {
        let s = settings(paragraph: 1000, jitter: 20)
        let pauses = (0..<20).map {
            PausePlanner.jitteredPauseMs(kind: .paragraphEnd, determinismKey: "same-chapter", segmentIndex: $0, settings: s)
        }
        XCTAssertGreaterThan(Set(pauses).count, 10, "Pausen klingen nicht mechanisch")
        for pause in pauses {
            XCTAssertGreaterThanOrEqual(pause, 800)
            XCTAssertLessThanOrEqual(pause, 1200)
        }
    }

    func testPausePlanCodableRoundTrip() throws {
        let plan = PausePlan(leadInMs: 600, tailMs: 900, pauseAfterMs: [0, 448, 802])
        let decoded = try JSONDecoder().decode(PausePlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
    }

    func testLineClassificationHelpers() {
        XCTAssertTrue(PausePlanner.isHeadingLine("2.3 Therapieoptionen"))
        XCTAssertFalse(PausePlanner.isHeadingLine("Dies ist ein ganzer Satz mit Punkt."))
        XCTAssertTrue(PausePlanner.isListItemLine("• Merkpunkt"))
        XCTAssertTrue(PausePlanner.isListItemLine("1. Erster Punkt"))
        XCTAssertTrue(PausePlanner.isListItemLine("- Mit Gedankenstrich"))
        XCTAssertFalse(PausePlanner.isListItemLine("Ganz normaler Satz."))
        XCTAssertTrue(PausePlanner.isFigureLine("Abbildung: Die Zelle."))
        XCTAssertTrue(PausePlanner.isFigureLine("Figure: The cell."))
        XCTAssertFalse(PausePlanner.isFigureLine("Die Abbildung zeigt nichts."))
    }
}

/// Plan 8.1 — VoiceID/VoiceCatalog data model + settings migration.
final class VoiceCatalogTests: XCTestCase {
    func testVoiceIDCodableRoundTrip() throws {
        let id = VoiceID(engine: .kokoroGerman, voice: "martin")
        let decoded = try JSONDecoder().decode(VoiceID.self, from: JSONEncoder().encode(id))
        XCTAssertEqual(decoded, id)
    }

    func testLegacySettingsMigrateToDefaultVoices() throws {
        // Old settings.json: per-engine voice keys, no defaultVoiceDE/EN.
        let legacy = """
        {
          "ttsEngine": "kokoro",
          "kokoroVoice": "af_bella",
          "piperVoice": "de_DE-thorsten-medium",
          "kokoroGermanVoice": "victoria"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        // German auto-select path: configured engine is not German-capable
        // → Piper suggestion, exactly like the old suggestEngineAndVoice.
        XCTAssertEqual(settings.defaultVoiceDE, VoiceID(engine: .piper, voice: "de_DE-thorsten-medium"))
        XCTAssertEqual(settings.defaultVoiceEN, VoiceID(engine: .kokoro, voice: "af_bella"))
    }

    func testGermanEngineSettingsMigrateToThatEngine() throws {
        let legacy = """
        {
          "ttsEngine": "kokoroGerman",
          "kokoroGermanVoice": "victoria"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.defaultVoiceDE, VoiceID(engine: .kokoroGerman, voice: "victoria"))
    }

    func testExplicitDefaultVoicesSurviveRoundTrip() throws {
        var settings = AppSettings()
        settings.defaultVoiceDE = VoiceID(engine: .kokoroGerman, voice: "martin")
        settings.defaultVoiceEN = VoiceID(engine: .piper, voice: "en_US-ryan-high")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.defaultVoiceDE, VoiceID(engine: .kokoroGerman, voice: "martin"))
        XCTAssertEqual(decoded.defaultVoiceEN, VoiceID(engine: .piper, voice: "en_US-ryan-high"))
    }

    func testLanguageAutoSelectionUsesDefaultVoices() {
        var settings = AppSettings()
        settings.defaultVoiceDE = VoiceID(engine: .kokoroGerman, voice: "martin")
        settings.defaultVoiceEN = VoiceID(engine: .kokoro, voice: "af_heart")

        XCTAssertEqual(LanguageDetector.suggestEngineAndVoice(languageCode: "de", settings: settings).voice, "martin")
        XCTAssertEqual(LanguageDetector.suggestEngineAndVoice(languageCode: "de", settings: settings).engine, .kokoroGerman)
        XCTAssertEqual(LanguageDetector.suggestEngineAndVoice(languageCode: "en-US", settings: settings).voice, "af_heart")

        settings.autoSelectEngineByLanguage = false
        XCTAssertEqual(LanguageDetector.suggestEngineAndVoice(languageCode: "de", settings: settings).engine, settings.ttsEngine)
    }

    func testCatalogContainsEveryFeaturedVoiceWithSample() {
        for profile in VoiceCatalog.allProfiles {
            XCTAssertFalse(profile.sampleText.isEmpty, "\(profile.displayName) braucht einen Beispielsatz")
            XCTAssertFalse(profile.displayName.isEmpty)
        }
        // Plan 8.2: the engine is never part of the visible name.
        for profile in VoiceCatalog.allProfiles {
            XCTAssertFalse(profile.displayName.contains("Kokoro"))
            XCTAssertFalse(profile.displayName.contains("Piper"))
        }
    }
}
