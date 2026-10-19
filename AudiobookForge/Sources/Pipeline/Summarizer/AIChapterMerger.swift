import Foundation

/// Merges AI chapters that came out below the minimum length
/// (`minAIChapterCharacters`, plan 7.2). Runs AFTER `splitOversizedChapters`:
/// by then every heading the model produced is a real chapter candidate, and
/// anything still tiny is structural noise — a one-sentence leftover section,
/// a split part, a stray preamble — that would sound like a chapter of its
/// own in the finished audiobook.
///
/// Rules (never across parent chapters, never loses a character):
/// - A chapter below the minimum merges with the FOLLOWING chapter of the
///   same parent, keeping the FIRST chapter's title; if the merged result is
///   still below the minimum, further following chapters of the same parent
///   are absorbed until it isn't.
/// - The LAST chapter of a parent that is still below the minimum is appended
///   to the previous chapter of the same parent.
/// - Chapters without a parent (`groupTitle == nil`, non-book documents)
///   merge with the PREVIOUS chapter.
/// - Merging joins the narration texts with a blank line — no new heading is
///   synthesized, because the model never saw this boundary.
enum AIChapterMerger {
    static func merge(_ chapters: [SummarizerClient.AIChapterResult], minCharacters: Int) -> [SummarizerClient.AIChapterResult] {
        guard minCharacters > 0, chapters.count > 1 else { return chapters }

        func groupKey(_ chapter: SummarizerClient.AIChapterResult) -> String {
            chapter.groupTitle ?? ""
        }

        func join(_ first: SummarizerClient.AIChapterResult, _ second: SummarizerClient.AIChapterResult) -> SummarizerClient.AIChapterResult {
            var merged = first
            merged.summarizedText = first.summarizedText + "\n\n" + second.summarizedText
            // The diff view shows the summary against the source; a merged
            // chapter may span two sources — the first one stays
            // representative, nothing narrated is lost either way.
            return merged
        }

        var result: [SummarizerClient.AIChapterResult] = []
        var index = 0
        while index < chapters.count {
            let current = chapters[index]
            let group = groupKey(current)
            let nextIsSameGroup = index + 1 < chapters.count && groupKey(chapters[index + 1]) == group

            if current.summarizedText.count >= minCharacters {
                result.append(current)
                index += 1
                continue
            }

            // Chapters without a parent prefer merging backward (their
            // "group" is only a positional run — e.g. split parts — so the
            // preceding chapter is the natural continuation).
            if current.groupTitle == nil, let previous = result.last, previous.groupTitle == nil {
                result[result.count - 1] = join(previous, current)
                index += 1
                continue
            }

            // Small chapter with following siblings of the same parent:
            // absorb following chapters until the minimum is reached.
            if nextIsSameGroup {
                var merged = current
                index += 1
                while merged.summarizedText.count < minCharacters,
                      index < chapters.count,
                      groupKey(chapters[index]) == group {
                    merged = join(merged, chapters[index])
                    index += 1
                }
                // Absorbed the whole group and still tiny (last of parent):
                // hand it to the backward rule below via the previous entry.
                if merged.summarizedText.count < minCharacters,
                   let previous = result.last, groupKey(previous) == group {
                    result[result.count - 1] = join(previous, merged)
                } else {
                    result.append(merged)
                }
                continue
            }

            // Last chapter of a parent group, still below the minimum:
            // append to the previous chapter of the same parent.
            if let previous = result.last, groupKey(previous) == group {
                result[result.count - 1] = join(previous, current)
            } else {
                // A single-chapter parent (or the very first chapter of the
                // document) stays as it is — never merge across parents.
                result.append(current)
            }
            index += 1
        }
        return result
    }
}
