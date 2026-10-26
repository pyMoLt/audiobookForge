import XCTest
@testable import AudiobookForge

/// v4: French, Spanish and Italian documents get the same structure
/// heuristics as German and English (headings, captions, front/back
/// matter, cross references, figure labels, default voices).
final class MultilingualHeuristicsTests: XCTestCase {
    func testChapterHeadingsInRomanceLanguages() {
        // Headings closer than three lines count as noise — real chapters are longer.
        let body = Array(repeating: "Une phrase assez longue pour former un vrai chapitre.", count: 4).joined(separator: "\n")
        let text = "Chapitre 1\n\(body)\nCapítulo 2\n\(body)\nCapitolo III\n\(body)"
        let chapters = ChapterHeadingHeuristic.split(fullText: text)
        XCTAssertEqual(chapters.count, 3, "\(chapters.map(\.title))")
    }

    func testMatterClassificationInRomanceLanguages() {
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Table des matières", text: "x"), .toc)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Índice", text: "x"), .toc)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Ringraziamenti", text: "x"), .frontMatter)
        XCTAssertEqual(FrontBackMatterClassifier.classify(title: "Bibliografía", text: "x"), .backMatter)
    }

    func testCaptionsAndCrossReferences() {
        XCTAssertTrue(PDFFigureDetector.isCaptionStart("Figura 3.2 Il ciclo"))
        XCTAssertTrue(PDFFigureDetector.isCaptionStart("Tableau 4 Résultats"))
        XCTAssertEqual(PDFTextbookCleaner.removeCrossReferences("Le cœur bat (voir p. 12) vite."), "Le cœur bat vite.")
        XCTAssertEqual(PDFTextbookCleaner.removeCrossReferences("El corazón (Figura 3) late."), "El corazón late.")
    }

    func testFigureLabelsPerLanguageArePausedLikeFigures() {
        XCTAssertEqual(PausePlanner.figureLabel(forLanguage: "it"), "Figura:")
        XCTAssertEqual(PausePlanner.figureLabel(forLanguage: "fr-FR"), "Illustration :")
        XCTAssertTrue(PausePlanner.isFigureLine("Figura: un grafico con due curve."))
        XCTAssertEqual(PausePlanner.plan("Figura: un grafico.").last?.kind, .figure)
    }

    func testImportPicksTheLanguagesDefaultVoice() {
        var settings = AppSettings()
        settings.autoSelectEngineByLanguage = true
        let italian = LanguageDetector.suggestEngineAndVoice(languageCode: "it", settings: settings)
        XCTAssertEqual(italian.engine, .pocketTTS)
        let french = LanguageDetector.suggestEngineAndVoice(languageCode: "fr", settings: settings)
        XCTAssertEqual(french.engine, .phonon)
    }
}
