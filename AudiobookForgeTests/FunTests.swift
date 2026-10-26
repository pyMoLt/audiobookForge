import XCTest
@testable import AudiobookForge

/// v4.3 easter eggs: achievements, Konami code, the long dog, sprites,
/// sounds, quips, settings defaults.
final class FunTests: XCTestCase {
    private func book(chapters: Int, seconds: Double = 60, language: String = "de") -> BookProject {
        var book = BookProject(title: "T", author: "", sourceType: .pdf, sourceURL: URL(fileURLWithPath: "/"), chapters: [],
                               outputFormat: .mp3Chapters, voice: "af_heart", speechSpeed: 1.0)
        book.chapters = (0..<chapters).map { index in
            var chapter = Chapter(title: "K\(index)", rawText: "", cleanedText: "", order: index)
            chapter.audioDurationSeconds = seconds
            return chapter
        }
        book.languageOverride = language
        book.status = .completed
        return book
    }

    func testAchievementsForAFinishedBook() {
        let calendar = Calendar(identifier: .gregorian)
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        let night = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 2))!
        let plain = book(chapters: 10)
        XCTAssertEqual(Achievement.earned(by: plain, completedBooks: [plain], at: noon, calendar: calendar), [.firstBook])
        XCTAssertTrue(Achievement.earned(by: plain, completedBooks: [plain], at: night, calendar: calendar).contains(.nightOwl))
        let answer = book(chapters: 42)
        XCTAssertTrue(Achievement.earned(by: answer, completedBooks: [answer], at: noon, calendar: calendar).contains(.answer42))
        let long = book(chapters: 600, seconds: 150)
        let earned = Achievement.earned(by: long, completedBooks: [long], at: noon, calendar: calendar)
        XCTAssertTrue(earned.contains(.longNeck))
        XCTAssertTrue(earned.contains(.marathon), "600 × 150 s = 25 h")
        let shelf = [book(chapters: 1, language: "de"), book(chapters: 1, language: "en"), book(chapters: 1, language: "fr"),
                     book(chapters: 1), book(chapters: 1)]
        let many = Achievement.earned(by: shelf[0], completedBooks: shelf, at: noon, calendar: calendar)
        XCTAssertTrue(many.contains(.polyglot))
        XCTAssertTrue(many.contains(.bookworm))
    }

    @MainActor
    func testKonamiCode() {
        let code = KonamiCodeMonitor.sequence
        XCTAssertTrue(KonamiCodeMonitor.matches(code))
        XCTAssertTrue(KonamiCodeMonitor.matches([126] + code), "an extra ↑ at the start still counts")
        XCTAssertTrue(KonamiCodeMonitor.matches([0, 11] + code))
        XCTAssertFalse(KonamiCodeMonitor.matches(Array(code.dropLast())))
        XCTAssertFalse(KonamiCodeMonitor.matches([126, 125, 126, 125, 123, 124, 123, 124, 11, 0]))
    }

    func testTheDogAppearsOnlyWhenTheBarOverflows() {
        XCTAssertEqual(ChapterTimelineView.naturalWidth(count: 1), 3)
        XCTAssertEqual(ChapterTimelineView.naturalWidth(count: 118), 118 * 3 + 117 * 2)
        XCTAssertGreaterThan(ChapterTimelineView.naturalWidth(count: 300), 900, "300 chapters overflow a normal window")
        XCTAssertLessThan(ChapterTimelineView.naturalWidth(count: 33), 900)
    }

    func testSpritesMirrorAndHaveAKnownPalette() {
        XCTAssertEqual(Sprites.mirrored(["ab.", "c"]), [".ba", "..c"])
        for sprite in [Sprites.dogHead, Sprites.dogBody, Sprites.owlWingsUp, Sprites.owlWingsDown, Sprites.heart, Sprites.letter] {
            for character in sprite.joined() where character != "." {
                XCTAssertNotNil(FunSprite.color(character, dark: false), "unknown pixel \(character)")
            }
        }
    }

    @MainActor
    func testEverySoundIsShortAndAudible() {
        for effect in SoundFX.Effect.allCases {
            let samples = SoundFX.samples(for: effect)
            XCTAssertGreaterThan(samples.count, 2000, "\(effect)")
            XCTAssertLessThan(Double(samples.count) / 44_100, 1.0, "\(effect) stays under a second")
            XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1)
        }
    }

    func testPlentyOfQuipsInBothLanguages() {
        XCTAssertGreaterThanOrEqual(LoadingQuips.german.count, 40)
        XCTAssertGreaterThanOrEqual(LoadingQuips.english.count, 40)
        XCTAssertEqual(Set(LoadingQuips.german).count, LoadingQuips.german.count)
    }

    @MainActor
    func testFunDefaultsForOldSettings() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.soundEffectsEnabled)
        XCTAssertTrue(settings.owlPostEnabled)
        XCTAssertTrue(settings.loadingQuipsEnabled)
        XCTAssertTrue(settings.lesserDogEnabled)
        XCTAssertFalse(settings.pixelMode, "pixel mode is opt-in")
        XCTAssertTrue(settings.unlockedAchievements.isEmpty)
        XCTAssertEqual(FunCenter.cascadeMessages.count, 4, "four ever more insistent questions")
    }
}
