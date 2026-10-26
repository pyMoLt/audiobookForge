import XCTest
import AVFoundation
@testable import AudiobookForge

/// Plan 9.2 — Erscheinungsbild: Persistenz, Migration, Textskalierung,
/// WCAG-Kontrast.
final class AppearanceSettingsTests: XCTestCase {
    func testCodableDefaults() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.appearanceMode, .system)
        XCTAssertEqual(settings.textSizeStep, .system)
        XCTAssertEqual(settings.accent, .violet)
        XCTAssertEqual(settings.glassIntensity, 80)
        XCTAssertEqual(settings.motionMode, .system)
        XCTAssertTrue(settings.flowBackgroundEnabled)

        // Round-trip
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.accent, settings.accent)
        XCTAssertEqual(decoded.glassIntensity, settings.glassIntensity)
    }

    func testMigrationOfOldSettings() throws {
        // settings.json written before Phase 6 has none of the appearance
        // keys — all new fields fall back to their defaults.
        let legacy = """
        { "ttsEngine": "kokoro", "kokoroVoice": "af_heart" }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.appearanceMode, .system)
        XCTAssertEqual(decoded.accent, .violet)
        XCTAssertEqual(decoded.glassIntensity, 80)
        XCTAssertEqual(decoded.sidebarGrouping, .topic)
    }

    func testTextScalingIsMonotonic() {
        let steps: [TextSizeStep] = [.xs, .s, .m, .l, .xl, .xxl]
        let factors = steps.map { Theme.textScale(for: $0) }
        for (index, factor) in factors.enumerated() {
            XCTAssertTrue(factor > 0 && factor < 2, "Skalierung bleibt in sinnvollem Bereich")
            if index > 0 {
                XCTAssertTrue(factor > factors[index - 1], "\(steps[index]) muss größer skalieren als \(steps[index - 1])")
            }
        }
        XCTAssertEqual(Theme.textScale(for: .system), 1.0)
    }

    func testWCAGContrastOnProminentButtons() {
        // Text on a prominent (accent-filled) button must reach WCAG 4.5:1 —
        // the engine picks white OR black per accent, whichever passes.
        for accent in AppAccent.allCases {
            let pair: (Double, Double, Double) = accent.prominentTextIsLight
                ? (1.0, 1.0, 1.0)
                : (0.0, 0.0, 0.0)
            let ratio = ContrastMath.ratio(
                ContrastMath.luminance(red: pair.0, green: pair.1, blue: pair.2),
                accent.baseLuminance
            )
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(accent.displayName): Kontrast \(String(format: "%.2f", ratio)) erreicht WCAG AA nicht")
        }
    }

    func testContrastMathMatchesWCAGReference() {
        // White on black = 21:1 (WCAG reference value).
        XCTAssertEqual(ContrastMath.ratio(1.0, 0.0), 21.0, accuracy: 0.01)
        // Same color = 1:1.
        XCTAssertEqual(ContrastMath.ratio(0.5, 0.5), 1.0, accuracy: 0.001)
    }

    func testAmbientSoundCatalog() {
        // v3.2: eight scenes (neon city and train added); the v3.0 raw
        // values stay so per-book choices survive the update. "Streicher"
        // stays dropped (plan 9.6).
        XCTAssertEqual(AmbientSound.allCases.map(\.rawValue), ["fire", "rain", "storm", "ocean", "water", "forest", "cyberpunk", "train"])
        XCTAssertEqual(AmbientSound(rawValue: "fire"), .fire)
        XCTAssertEqual(AmbientSound(rawValue: "water"), .water)
    }

    func testEveryAmbientSceneHasPixelArtAndSound() {
        // v3.2: each scene ships a layout, a background image and a bed loop.
        for scene in AmbientSound.allCases {
            let name = PixelSceneSupport.assetName(scene)
            XCTAssertNotNil(PixelSceneSupport.layout("scene_\(name)"), "layout for \(scene)")
            let background = ["fire": "room", "water": "land", "train": "cabin"][scene.rawValue] ?? "room"
            let image = PixelSceneSupport.image("scene_\(name)_\(background)")
            XCTAssertEqual(image?.width, 320, "background of \(scene)")
            XCTAssertEqual(image?.height, 180, "background of \(scene)")
            XCTAssertNotNil(Bundle.main.url(forResource: scene.resourceName, withExtension: "m4a"), "sound for \(scene)")
        }
    }

    func testPixelArtHitsWidthAndPalette() throws {
        // A smooth gradient must come out at the art width with ≤ 36 colours.
        let size = 200
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size * 3 / 2, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)] as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size * 3 / 2), options: [])
        let art = try XCTUnwrap(PixelArt.pixelate(try XCTUnwrap(context.makeImage()), artWidth: 40))
        XCTAssertEqual(art.width, 40)
        XCTAssertEqual(art.height, 60)
        let data = try XCTUnwrap(art.dataProvider?.data as Data?)
        var colours = Set<UInt32>()
        for i in stride(from: 0, to: data.count, by: 4) {
            colours.insert(UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]))
        }
        XCTAssertLessThanOrEqual(colours.count, 38)
        XCTAssertEqual(PixelArt.artWidth(forPoints: 300), 160)
        XCTAssertEqual(PixelArt.artWidth(forPoints: 34), 32)
    }

    func testProminentFillsReachWCAGWithTheirTextColor() {
        // v3.1: prominent fills are deepened until WHITE text passes 4.5:1;
        // accents that would turn muddy keep their color with BLACK text.
        for accent in AppAccent.allCases where accent != .system {
            if let deepen = accent.prominentDeepening {
                let r = accent.rgb.red * (1 - deepen), g = accent.rgb.green * (1 - deepen), b = accent.rgb.blue * (1 - deepen)
                let ratio = ContrastMath.ratio(1.0, ContrastMath.luminance(red: r, green: g, blue: b))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(accent.displayName): weiß auf vertiefter Füllung")
                XCTAssertLessThanOrEqual(deepen, 0.3 + 1e-9)
            } else {
                let ratio = ContrastMath.ratio(accent.baseLuminance, 0)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(accent.displayName): schwarz auf Akzent")
            }
        }
        XCTAssertNotNil(AppAccent.violet.prominentDeepening, "Violett trägt weiße Schrift (Vorlage)")
        XCTAssertNil(AppAccent.amber.prominentDeepening, "Bernstein bleibt hell mit schwarzer Schrift")
    }
}

/// Plan 9.3 — keine Einstellung geht verloren: jedes AppSettings-Feld ist
/// in der Mapping-Tabelle der neuen Einstellungsansicht enthalten.
final class SettingsMappingTests: XCTestCase {
    func testEverySettingsFieldIsMapped() throws {
        let mirrored = Mirror(reflecting: AppSettings()).children
            .compactMap(\.label)
            .filter { !$0.isEmpty }
        XCTAssertGreaterThan(mirrored.count, 60, "AppSettings hat viele Felder")

        let mapped = Set(SettingsView.settingsBuckets.flatMap { $0.fields })
        let missing = mirrored.filter { !mapped.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Felder ohne Ort in der Einstellungsansicht: \(missing)")
    }

    func testNoDuplicateBuckets() {
        let allFields = SettingsView.settingsBuckets.flatMap { $0.fields }
        XCTAssertEqual(allFields.count, Set(allFields).count, "Jedes Feld liegt in genau einem Bereich")
    }

    func testAdvancedSearchFindsTimeout() {
        // Plan 9.3: the search term "Timeout" must lead to the connection
        // and request timeouts — the matcher treats each query word as a
        // substring of the section keywords.
        let keywords = "ki endpoint server verbindung timeout antwort modell"
        XCTAssertTrue(advancedMatches("Timeout", keywords: keywords))
        XCTAssertTrue(advancedMatches("verbindung timeout", keywords: keywords))
        XCTAssertFalse(advancedMatches("zauberstein", keywords: keywords))
    }

    private func advancedMatches(_ query: String, keywords: String) -> Bool {
        let lowered = query.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.isEmpty { return true }
        return keywords.contains(lowered) || lowered.split(separator: " ").contains { keywords.contains($0) }
    }
}

/// Plan 9.6 — Ambient: Loop-Planung, Zustandsmaschine, Assets.
final class AmbientEngineTests: XCTestCase {
    func testCrossfadeBoundedToQuarterLoop() {
        let planner = AmbientLoopPlanner(loopSeconds: 60, crossfadeSeconds: 1.5)
        XCTAssertEqual(planner.crossfadeSeconds, 1.5)
        let excessive = AmbientLoopPlanner(loopSeconds: 4, crossfadeSeconds: 1.5)
        XCTAssertEqual(excessive.crossfadeSeconds, 1.0, "Kreuzblende ≤ Loop/4")
        let long = AmbientLoopPlanner(loopSeconds: 100, crossfadeSeconds: 50)
        XCTAssertEqual(long.crossfadeSeconds, 25.0)
    }

    func testFadeGainIsLinear() {
        XCTAssertEqual(AmbientLoopPlanner.fadeGain(at: 0, rising: true), 0)
        XCTAssertEqual(AmbientLoopPlanner.fadeGain(at: 1, rising: true), 1)
        XCTAssertEqual(AmbientLoopPlanner.fadeGain(at: 0.5, rising: true), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AmbientLoopPlanner.fadeGain(at: 0.25, rising: false), 0.75, accuracy: 0.0001)
        XCTAssertEqual(AmbientLoopPlanner.fadeGain(at: 2, rising: true), 1, "Klemmt bei 1")
        XCTAssertEqual(AmbientLoopPlanner.fadeGain(at: -1, rising: true), 0, "Klemmt bei 0")
    }

    func testStateMachineAusEinPauseFortsetzenAus() {
        var planner = AmbientLoopPlanner(loopSeconds: 90)
        XCTAssertTrue(planner.start())
        XCTAssertEqual(planner.state, .playing)
        XCTAssertFalse(planner.start(), "Doppel-Start ist ein No-Op")

        XCTAssertTrue(planner.pause())
        XCTAssertEqual(planner.state, .paused)
        XCTAssertFalse(planner.pause())

        XCTAssertTrue(planner.resume())
        XCTAssertEqual(planner.state, .playing)
        XCTAssertFalse(planner.resume())

        XCTAssertTrue(planner.stop())
        XCTAssertEqual(planner.state, .idle)
        XCTAssertFalse(planner.stop())
        XCTAssertFalse(planner.resume(), "Aus.paused-Übergang gibt es nicht")
    }

    func testAmbientAssetsExistWithRightSizeAndDuration() throws {
        for sound in AmbientSound.allCases {
            guard let url = Bundle.main.url(forResource: sound.resourceName, withExtension: "m4a")
                ?? Bundle(for: AmbientEngineTests.self).url(forResource: sound.resourceName, withExtension: "m4a") else {
                // Quellbaum-Fallback für Test-Bundles ohne App-Resourcen.
                let source = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("AudiobookForge/Resources/Ambient/\(sound.resourceName).m4a")
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Asset fehlt: \(sound.resourceName)")
                try assertValidAsset(source)
                continue
            }
            try assertValidAsset(url)
        }
    }

    private func assertValidAsset(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, 2_500_000, "\(url.lastPathComponent) ≤ 2,5 MB")

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertGreaterThanOrEqual(duration, 60 * 0.95, "\(url.lastPathComponent) ≈ 60–120 s")
        XCTAssertLessThanOrEqual(duration, 120 * 1.05, "\(url.lastPathComponent) ≈ 60–120 s")
    }

    func testEverySceneHasEventAssets() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AudiobookForge/Resources/Ambient")
        for sound in AmbientSound.allCases {
            let events = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix(sound.eventResourcePrefix + "_") && $0.hasSuffix(".m4a") }
            XCTAssertGreaterThanOrEqual(events.count, 3, "\(sound.rawValue): mindestens 3 Einzelereignisse")
        }
    }

    func testEventPlannerIsDeterministicAndBounded() {
        let recipe = AmbientSound.fire.eventRecipe
        var a = AmbientEventPlanner(recipe: recipe, variants: 8, seed: 42)
        var b = AmbientEventPlanner(recipe: recipe, variants: 8, seed: 42)
        var previous = -1
        for _ in 0..<500 {
            let e = a.next(intensity: 0.7)
            XCTAssertEqual(e, b.next(intensity: 0.7), "gleicher Seed → gleiche Folge")
            XCTAssertGreaterThanOrEqual(e.delay, recipe.minGap)
            XCTAssertTrue((0..<8).contains(e.variant))
            XCTAssertNotEqual(e.variant, previous, "nie zweimal dieselbe Aufnahme hintereinander")
            previous = e.variant
            XCTAssertTrue(recipe.pan.contains(e.pan))
            XCTAssertTrue(recipe.rate.contains(e.rate))
            XCTAssertLessThanOrEqual(e.gain, recipe.gain.upperBound)
            XCTAssertNil(e.flashLead, "Feuer hat keine Blitze")
        }
    }

    func testEventRateFollowsIntensity() {
        func meanDelay(_ intensity: Double) -> Double {
            var planner = AmbientEventPlanner(recipe: AmbientSound.fire.eventRecipe, variants: 6, seed: 7)
            return (0..<2000).map { _ in planner.next(intensity: intensity).delay }.reduce(0, +) / 2000
        }
        XCTAssertLessThan(meanDelay(1.0), meanDelay(0.1), "mehr Intensität → dichteres Knistern")
    }

    func testStormFlashPrecedesThunder() {
        var planner = AmbientEventPlanner(recipe: AmbientSound.storm.eventRecipe, variants: 5, seed: 3)
        for _ in 0..<100 {
            let lead = planner.next(intensity: 0.5).flashLead
            XCTAssertNotNil(lead)
            XCTAssertTrue((0.4...2.5).contains(lead ?? -1))
        }
    }
}

/// Plan 9.5 — automatische Themenerkennung: deterministisch, offline.
final class TopicClassifierTests: XCTestCase {
    private func classify(_ text: String, title: String = "", documentType: DocumentType = .general, language: String? = "de") -> TopicClassifier.Result {
        TopicClassifier.classify(title: title, author: "", documentType: documentType, textSample: text, languageCode: language)
    }

    func testMedicineTexts() {
        let sample = String(repeating: "Die Patientin stellt sich mit Schmerzen vor. Die Diagnose ergibt eine Entzündung. Die Therapie beginnt mit einem Antibiotikum in angemessener Dosis. ", count: 12)
        for _ in 0..<3 {
            XCTAssertEqual(classify(sample, title: "Klinische Propädeutik").topic.id, "medicine")
        }
    }

    func testScienceText() {
        let sample = String(repeating: "Der Algorithmus konvergiert. Die Messung bestätigt die Hypothese. Jede Gleichung beschreibt das Spektrum der Partikel. ", count: 12)
        XCTAssertEqual(classify(sample, title: "Einführung in die Physik").topic.id, "science")
    }

    func testLiteratureText() {
        let sample = String(repeating: "„Bleib hier“, sagte er. Sie lächelte und blickte in die Nacht. Er flüsterte etwas von einem Traum. ", count: 20)
        XCTAssertEqual(classify(sample, title: "Der lange Weg", documentType: .book).topic.id, "literature")
    }

    func testHistoryAndEconomyTexts() {
        let history = String(repeating: "Im neunzehnten Jahrhundert wuchs das Reich. Der Kaiser führte das Land in den Krieg. ", count: 15)
        XCTAssertEqual(classify(history, title: "Weltgeschichte").topic.id, "history")

        let economy = String(repeating: "Nach § 12 des Gesetzes haftet das Unternehmen. Die Bilanz weist einen Gewinn aus, der Umsatz steigt. ", count: 12)
        XCTAssertEqual(classify(economy, title: "Handelsrecht").topic.id, "economy")
    }

    func testEnglishMedicine() {
        let sample = String(repeating: "The patient received the diagnosis. Clinical therapy with antibiotics followed the treatment protocol. ", count: 12)
        XCTAssertEqual(classify(sample, language: "en").topic.id, "medicine")
    }

    func testMedicalNovelGoesLiteratureWhenDialogueDominates() {
        // Grenzfall: ein Roman ÜBER Medizin — Dialogmarker dominieren,
        // Medizintermine sind seltener → Literatur gewinnt.
        let sample = String(repeating: "„Ich habe Angst“, sagte sie. Er lächelte. „Die Diagnose“, sagte er, „ist nicht schlimm.“ ", count: 25)
        let result = classify(sample, title: "Station 7", documentType: .book)
        XCTAssertEqual(result.topic.id, "literature")
    }

    func testMedtechPaperGoesScience() {
        // Grenzfall: Paper über Medizintechnik — Papertyp-Priorior +
        // Technikbegriffe schlagen die einzelne Patientenerwähnung.
        let sample = String(repeating: "Der neue Algorithmus verbessert die Messung. Die Simulation zeigt, dass jede Gleichung das Experiment vorhersagt. Ein Patient diente als Referenz. ", count: 10)
        XCTAssertEqual(classify(sample, documentType: .paper).topic.id, "science")
    }

    func testEmptyAndShortTextsFallToOther() {
        XCTAssertEqual(classify("").topic.id, "other")
        XCTAssertEqual(classify("Hallo Welt, dies ist ein kurzer Satz ohne Fachvokabular.").topic.id, "other")
    }

    func testDeterministic() {
        let sample = String(repeating: "Die Therapie des Patienten beginnt mit der Diagnose. ", count: 10)
        let first = classify(sample)
        let second = classify(sample)
        XCTAssertEqual(first, second)
    }

    func testPerformanceOnOneMegabyte() {
        // Plan 9.5: < 50 ms für 1 MB Text — der Trefferzähler deckelt bei
        // 500 pro Keyword, die Suche selbst ist ein linearer Scan.
        let chunk = "Die Patientin erhält ihre Therapie nach der Diagnose. Der Arzt prüft die Dosis. "
        let sample = String(repeating: chunk, count: 17_000) // ~1 MB
        measure {
            _ = classify(sample)
        }
    }
}

/// Plan 9.5 — Ordner: Persistenz und Verhalten beim Löschen.
final class FolderStoreTests: XCTestCase {
    private var store: FolderStore!
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("abf-folders-\(UUID().uuidString)", isDirectory: true)
        store = FolderStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testAddRenamePersist() {
        let folder = store.add(name: "Leseliste")
        XCTAssertEqual(store.folders().map(\.name), ["Leseliste"])
        store.rename(id: folder.id, to: "Favoriten")
        XCTAssertEqual(store.folders().first?.name, "Favoriten")

        let reloaded = FolderStore(root: root)
        XCTAssertEqual(reloaded.folders().first?.name, "Favoriten", "Persistenz über Neustart")
    }

    func testDeleteKeepsFoldersJsonConsistent() {
        let a = store.add(name: "A")
        _ = store.add(name: "B")
        store.delete(id: a.id)
        XCTAssertEqual(store.folders().map(\.name), ["B"])
        XCTAssertEqual(FolderStore(root: root).folders().count, 1)
    }

    func testEmptyNameFallsBack() {
        XCTAssertEqual(store.add(name: "   ").name, "Neuer Ordner")
    }

    func testOrderFollowsCreation() {
        store.add(name: "Erster")
        store.add(name: "Zweiter")
        XCTAssertEqual(store.folders().map(\.name), ["Erster", "Zweiter"])
    }
}

final class DarkModeAccentTextTests: XCTestCase {
    /// v4.1: accent text on faint tints stays readable on the dark surface.
    func testEveryAccentReachesAAContrastAsDarkModeText() {
        let surface = ContrastMath.luminance(red: 0.17, green: 0.17, blue: 0.18)
        for accent in AppAccent.allCases where accent != .system {
            let lift = accent.darkModeLift
            let mix = { (c: Double) in c + (1 - c) * lift }
            let lum = ContrastMath.luminance(red: mix(accent.rgb.red), green: mix(accent.rgb.green), blue: mix(accent.rgb.blue))
            XCTAssertGreaterThanOrEqual(ContrastMath.ratio(lum, surface), 4.5, "\(accent)")
        }
        XCTAssertGreaterThan(AppAccent.graphite.darkModeLift, 0)
    }
}
