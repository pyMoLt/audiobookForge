import Foundation

/// Format-agnostic chapter clean-up applied after extraction, regardless of
/// whether the chapters came from a PDF outline, a PDF heading heuristic, or
/// an EPUB's table of contents. Two independent problems, one place to fix
/// them for every document type:
/// - Some documents produce far too many tiny "chapters" (a stray heading,
///   a sub-section, a fragment of front matter that slipped through).
/// - Papers routinely end in sections nobody wants narrated in full
///   (a 30-minute recitation of a references list serves no one).
enum ChapterPostProcessor {
    private static let backMatterTitlePatterns: [String] = [
        #"^references$"#, #"^bibliography$"#, #"^works cited$"#,
        #"^acknowledge?ments?$"#, #"^supplementary material$"#,
        #"^supporting information$"#, #"^(foot|end)notes$"#, #"^index$"#,
        #"^(the )?full project gutenberg.*license$"#,
        // German textbooks/scripts: listings that are useless read aloud.
        #"^(inhaltsverzeichnis|inhalt|contents|table of contents)$"#,
        #"^(sach|stichwort|personen|namens)?(verzeichnis|register)$"#,
        #"^(sachverzeichnis|stichwortverzeichnis|literaturverzeichnis|quellenverzeichnis|abbildungsverzeichnis|tabellenverzeichnis|abkürzungsverzeichnis|bildnachweis|abbildungsnachweis|impressum)$"#,
        #"^literatur$"#, #"^quellen$"#,
    ]

    static func isBackMatterSection(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return backMatterTitlePatterns.contains { pattern in
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Length without invisible figure markers (they carry encoded
    /// metadata and would make a figure-only fragment look long).
    static func visibleLength(_ text: String) -> Int {
        ImageDescriptionMarker.stripPlaceholders(from: text).count
    }

    static func filterBackMatter(_ chapters: [ExtractedChapter]) -> [ExtractedChapter] {
        chapters.filter { !isBackMatterSection(title: $0.title) }
    }

    /// Folds any chapter shorter than `minimumCharacters` into the previous
    /// chapter (or the next one, if it's the very first) — a stray heading,
    /// a leftover fragment, or a genuinely tiny section all read the same
    /// way to this pass: too short to stand alone, safe to attach to a
    /// neighbor rather than either dropping it or narrating it in isolation
    /// for a few seconds.
    static func mergeUndersizedChapters(_ chapters: [ExtractedChapter], minimumCharacters: Int) -> [ExtractedChapter] {
        guard chapters.count > 1, minimumCharacters > 0 else { return chapters }

        var result: [ExtractedChapter] = []
        for chapter in chapters {
            if visibleLength(chapter.text) < minimumCharacters, !result.isEmpty {
                result[result.count - 1].text += "\n\n" + chapter.text
            } else {
                result.append(chapter)
            }
        }

        while result.count > 1, visibleLength(result[0].text) < minimumCharacters {
            let first = result.removeFirst()
            result[0].text = first.text + "\n\n" + result[0].text
        }

        return result
    }
}
