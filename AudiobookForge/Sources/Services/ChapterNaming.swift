import Foundation

/// Builds the chapter names written into the packaged audiobook (M4B chapter
/// marks, MP3 file/tag titles) from `Chapter.title` + `Chapter.groupTitle`
/// (plan 7.3). Separate from `Chapter.displayTitle` (UI) so packaging can
/// never depend on view code.
///
/// - Base name: "Gruppe — Titel"; without a group just the title.
/// - From 70 characters on, the name is shortened to "N · Titel" where N is
///   the position of the parent chapter (group) within the book — players
///   truncate long marks visually, and the group number keeps navigation
///   possible even when the group name is gone.
/// - Duplicate final names get " (2)", " (3)" … so every mark is unique.
///   Display-only — `Chapter.title` is never modified.
enum ChapterNaming {
    static let shorteningThreshold = 70

    /// Chapter mark names for the given chapters, in order.
    static func markTitles(for chapters: [Chapter]) -> [String] {
        // Ordinal of each group (by first appearance), 1-based; chapters
        // without a group count as their own single-chapter group, numbered
        // by their own position.
        var groupOrdinals: [String: Int] = [:]
        var nextOrdinal = 1
        // Duplicate TITLES (plan 7.3): the same AI heading can appear under
        // several parent chapters — every occurrence after the first gets
        // " (2)", " (3)" … so the marks stay distinguishable.
        var titleCounts: [String: Int] = [:]
        for chapter in chapters { titleCounts[chapter.title, default: 0] += 1 }
        var titleSeen: [String: Int] = [:]
        var finalSeen: Set<String> = []

        return chapters.enumerated().map { position, chapter in
            let groupKey = chapter.groupTitle ?? ""
            let ordinal: Int
            if let existing = groupOrdinals[groupKey] {
                ordinal = existing
            } else if groupKey.isEmpty {
                // Without a group the chapter is its own group — numbered by
                // its position in the book.
                ordinal = position + 1
            } else {
                ordinal = nextOrdinal
                groupOrdinals[groupKey] = ordinal
                nextOrdinal += 1
            }

            var name = chapter.displayTitle
            if name.count >= shorteningThreshold {
                name = "\(ordinal) · \(chapter.title)"
            }
            if titleCounts[chapter.title]! > 1 {
                let occurrence = (titleSeen[chapter.title] ?? 0) + 1
                titleSeen[chapter.title] = occurrence
                if occurrence > 1 {
                    name += " (\(occurrence))"
                }
            }
            return uniquified(name, seen: &finalSeen)
        }
    }

    private static func uniquified(_ name: String, seen: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        while seen.contains(candidate) {
            candidate = "\(name) (\(counter))"
            counter += 1
        }
        seen.insert(candidate)
        return candidate
    }
}
