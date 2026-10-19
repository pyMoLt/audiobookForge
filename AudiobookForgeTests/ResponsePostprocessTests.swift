import XCTest
@testable import AudiobookForge

/// Plan 7.5 — response post-processing with synthetic answers.
final class ResponsePostprocessTests: XCTestCase {
    func testLeadingMetaPhrasesAreRemoved() {
        let german = "Hier ist die Zusammenfassung des Abschnitts:\n\n## Einführung\nDer Text beginnt."
        XCTAssertEqual(ResponsePostprocess.stripLeadingMetaPhrases(german), "## Einführung\nDer Text beginnt.")
        let english = "Sure, here is the summary:\n\n## Method\nThe method."
        XCTAssertEqual(ResponsePostprocess.stripLeadingMetaPhrases(english), "## Method\nThe method.")
        let zusammenfassend = "Zusammenfassend lässt sich sagen: alles gut.\n\n## Fazit\nEs bleibt dabei."
        XCTAssertEqual(ResponsePostprocess.stripLeadingMetaPhrases(zusammenfassend), "## Fazit\nEs bleibt dabei.")
    }

    func testNormalOpeningIsNotTouched() {
        let normal = "## Einführung\nDie Anamnese steht am Anfang."
        XCTAssertEqual(ResponsePostprocess.stripLeadingMetaPhrases(normal), normal)
        // A lone meta-ish line is kept — never empty out an answer.
        let single = "Zusammenfassend: kurz."
        XCTAssertEqual(ResponsePostprocess.stripLeadingMetaPhrases(single), single)
    }

    func testDuplicateConsecutiveHeadingsCollapse() {
        let doubled = "## Erster Titel\n## Zweiter Titel\n\nInhalt gehört zum zweiten."
        XCTAssertEqual(ResponsePostprocess.collapseDuplicateHeadings(doubled), "## Zweiter Titel\nInhalt gehört zum zweiten.")
        let withBlanks = "## A\n\n## B\n\nInhalt."
        XCTAssertEqual(ResponsePostprocess.collapseDuplicateHeadings(withBlanks), "## B\nInhalt.")
        let tripled = "## A\n## B\n## C\nInhalt."
        XCTAssertEqual(ResponsePostprocess.collapseDuplicateHeadings(tripled), "## C\nInhalt.")
    }

    func testDistinctHeadingsSurvive() {
        let normal = "## Einleitung\nText.\n\n## Methode\nMehr Text."
        XCTAssertEqual(ResponsePostprocess.collapseDuplicateHeadings(normal), normal)
    }

    func testContextMarkerLineIsRemoved() {
        let echoed = "## Kapitel\nInhalt.\n[Context — already covered, do not summarize again]\nMehr Inhalt."
        let cleaned = ResponsePostprocess.stripContextEcho(echoed, context: nil)
        XCTAssertFalse(cleaned.contains("[Context"))
        XCTAssertTrue(cleaned.contains("Inhalt."))
        XCTAssertTrue(cleaned.contains("Mehr Inhalt."))
    }

    func testEchoedContextSentencesAreRemoved() {
        let context = "Der Patient stellt sich mit akuten Schmerzen vor. Die Anamnese ergab einen Unfall."
        let echoed = "## Befund\nDer Patient stellt sich mit akuten Schmerzen vor. Neue Erkenntnisse folgen."
        let cleaned = ResponsePostprocess.stripContextEcho(echoed, context: context)
        XCTAssertFalse(cleaned.contains("Der Patient stellt sich"))
        XCTAssertTrue(cleaned.contains("Neue Erkenntnisse folgen."))
        // Non-echoed text from a similar sentence stays.
        XCTAssertTrue(ResponsePostprocess.stripContextEcho("## Befund\nDie Anamnese ergab Neues.", context: context).contains("Die Anamnese ergab Neues."))
    }

    func testCleanPassesWellBehavedResponsesThrough() {
        let good = "## Einleitung\nSauberer, zusammenhängender Text über zwei Zeilen.\n\n## Methode\nAuch sauber."
        XCTAssertEqual(ResponsePostprocess.clean(good), good)
    }

    func testFullCleanupCombinesAllRules() {
        let context = "Der Patient stellt sich mit akuten Schmerzen vor."
        let response = """
        Hier ist die Zusammenfassung:

        ## Überschrift A
        ## Überschrift B
        [Context — already covered, do not summarize again]
        Der Patient stellt sich mit akuten Schmerzen vor.
        Eigentlich neuer Inhalt.
        """
        let cleaned = ResponsePostprocess.clean(response, echoedContext: context)
        XCTAssertEqual(cleaned, "## Überschrift B\nEigentlich neuer Inhalt.")
    }
}
