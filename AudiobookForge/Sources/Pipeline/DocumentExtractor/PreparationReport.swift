import Foundation

/// "Vorbereitung prüfen" (plan 6.7): a pure, testable summary of what
/// the text preparation will do to a book with the CURRENT settings —
/// counters per rule plus the list of suspicious chapters (mini
/// chapters, lowercase starts, TOC suggestions). Nothing here modifies
/// the book; the review screen renders it before the run starts.
struct PreparationReport: Sendable, Equatable {
    var boxLabelOnlyLines = 0
    var boxLabelPrefixes = 0
    var listItems = 0
    var headingNumbersStripped = 0
    var tocSuggested = 0
    var excludedByUser = 0
    var miniChapters = 0
    var lowercaseStartChapters = 0
    /// Titles of suspicious chapters (mini or lowercase start), capped.
    var suspiciousChapters: [String] = []

    /// Plan threshold: chapters under 800 characters get a warning icon.
    static let miniChapterThreshold = 800

    static func build(chapters: [Chapter], settings: AppSettings) -> PreparationReport {
        var report = PreparationReport()
        var suspicious: [String] = []

        for chapter in chapters {
            let labelPass = BoxLabelFilter.apply(chapter.cleanedText, handling: settings.boxLabelHandling)
            report.boxLabelOnlyLines += labelPass.report.removedLabelLines
            report.boxLabelPrefixes += labelPass.report.strippedPrefixes

            let listPass = ListNumberingFilter.apply(labelPass.text, speakHeadingNumbers: settings.speakHeadingNumbers)
            report.listItems += listPass.report.listItems
            report.headingNumbersStripped += listPass.report.headingNumbersStripped

            if let kind = chapter.matterKind, FrontBackMatterClassifier.suggestsSkipping(kind), chapter.includeInNarration != true {
                report.tocSuggested += 1
            }
            if chapter.includeInNarration == false {
                report.excludedByUser += 1
            }

            let isMini = chapter.cleanedText.count < miniChapterThreshold
            let startsLowercase = chapter.cleanedText.first.map { $0.isLowercase } ?? false
            if isMini { report.miniChapters += 1 }
            if startsLowercase { report.lowercaseStartChapters += 1 }
            if isMini || startsLowercase {
                suspicious.append(chapter.title)
            }
        }
        report.suspiciousChapters = Array(suspicious.prefix(12))
        return report
    }
}
