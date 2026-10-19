import Foundation

enum DocumentImportService {
    static func importDocument(at url: URL, settings: AppSettings) async throws -> BookProject {
        guard let extractor = DocumentExtractorFactory.extractor(for: url, settings: settings) else {
            throw DocumentExtractionError.unsupportedFormat(url.pathExtension)
        }

        let extracted = try await extractor.extract(from: url)

        var processedChapters = extracted.chapters
        if settings.excludeBackMatterSections {
            processedChapters = ChapterPostProcessor.filterBackMatter(processedChapters)
        }
        let minimumChapterCharacters = settings.minimumChapterCharacters(for: settings.defaultDocumentType)
        processedChapters = ChapterPostProcessor.mergeUndersizedChapters(processedChapters, minimumCharacters: minimumChapterCharacters)

        // Auto-split fallback: if only one chapter remains (no TOC, no heading
        // heuristic matches) and the text is long enough, split it into
        // roughly equal segments at paragraph boundaries so the user gets a
        // navigable chapter structure rather than one monolithic block.
        if processedChapters.count == 1 && settings.autoSplitEnabled {
            let singleText = processedChapters[0].text
            if singleText.count > settings.autoSplitTargetCharacters {
                processedChapters = ChapterHeadingHeuristic.splitEvenly(
                    fullText: singleText,
                    targetCharacters: settings.autoSplitTargetCharacters
                )
            }
        }

        let sourceType: SourceDocumentType = url.pathExtension.lowercased() == "epub" ? .epub : .pdf
        let rawChapters = processedChapters.enumerated().map { index, chapter in
            Chapter(
                title: chapter.title,
                rawText: chapter.text,
                cleanedText: chapter.text,
                order: index
            )
        }

        let targetSize = settings.targetChapterCharacters
        var initialChapters = (settings.minimumChapterCharacters > 0 && targetSize > 0)
            ? ChapterRebundler.rebundle(chapters: rawChapters, targetCharacters: targetSize)
            : rawChapters

        // Document-role classification (plan 6.2): TOC/front-matter chapters
        // get the "nicht vorlesen" suggestion in the review screen. Purely
        // a suggestion — the user can always override it.
        for chapterIndex in initialChapters.indices {
            initialChapters[chapterIndex].matterKind = FrontBackMatterClassifier.classify(
                title: initialChapters[chapterIndex].title,
                text: initialChapters[chapterIndex].cleanedText
            )
            // Numbering helps the eye, not the ear (plan 6.4).
            initialChapters[chapterIndex].title = ListNumberingFilter.cleanedTitle(initialChapters[chapterIndex].title)
        }

        // Sentence-boundary repair across chapter splits (plan 6.5):
        // fragments that begin mid-sentence move back to their
        // predecessor. The geometric root cause (outline target matching
        // in PDFExtractor) is documented separately.
        initialChapters = ChapterBoundaryRepair.repairBoundaries(chapters: initialChapters)

        let detectedLanguage = LanguageDetector.detectLanguageCode(chapterTexts: extracted.chapters.map(\.text))
        let suggestion = LanguageDetector.suggestEngineAndVoice(languageCode: detectedLanguage, settings: settings)

        var note = sourceType == .pdf ? "Erstellt aus PDF" : "Erstellt aus EPUB"
        note += " via \(suggestion.engine.displayName)"
        if extracted.usedOCR {
            note += " (Text via OCR erkannt)"
        }

        return BookProject(
            title: extracted.suggestedTitle,
            author: extracted.suggestedAuthor,
            sourceType: sourceType,
            sourceURL: url,
            chapters: initialChapters,
            documentType: settings.defaultDocumentType,
            rawImportedChapters: rawChapters,
            targetChapterCharacters: targetSize,
            summarizationBudget: settings.summarizationChunkCharacterBudget(for: settings.defaultDocumentType),
            outputFormat: settings.defaultOutputFormat,
            engineID: suggestion.engine,
            voice: suggestion.voice,
            speechSpeed: settings.defaultSpeed(for: suggestion.engine),
            detectedLanguageCode: detectedLanguage,
            sourceNote: note,
            coverImageData: extracted.coverImageData.flatMap { ImageConversion.toJPEG($0) },
            detectedImageCount: extracted.detectedImageCount
        )
    }
}
