import Foundation

struct MP3ChapterPackager: ChapterPackager {
    let settings: AppSettings

    func package(
        book: BookProject,
        chapterAudioFiles: [ChapterAudioFile],
        outputDirectory: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        guard !chapterAudioFiles.isEmpty else { throw PackagerError.noChapterAudio }
        guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settings) else { throw PackagerError.ffmpegNotFound }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let ordered = chapterAudioFiles.sorted { $0.chapter.order < $1.chapter.order }
        let totalCount = ordered.count
        // Chapters now arrive pre-encoded as MP3 matching the book's
        // quality setting, so packaging is a metadata-only stream copy.
        // Foreign inputs (e.g. AAC chapters after a format switch) are
        // still transcoded once.
        let alreadyMP3 = ordered.first?.url.pathExtension.lowercased() == "mp3"
        // Plan 7.3: same mark names as the M4B ("Gruppe — Titel", shortened,
        // deduplicated) so both formats navigate identically.
        let markTitles = ChapterNaming.markTitles(for: ordered.map(\.chapter))

        // Inputs can BE the files in the output folder (a finished MP3 book
        // whose chapter is regenerated): deleting the destination first
        // deleted the source and lost the chapter (v3.2 bug, "01 - …mp3"
        // gone). Write everything into a staging folder on the same volume
        // and swap only when every chapter succeeded.
        let fm = FileManager.default
        let staging = outputDirectory.appendingPathComponent(".abf-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var finished: [String] = []

        for (index, item) in ordered.enumerated() {
            let trackNumber = index + 1
            let markTitle = markTitles[index]
            let fileName = String(format: "%02d - %@.mp3", trackNumber, sanitize(markTitle))
            let destination = staging.appendingPathComponent(fileName)
            finished.append(fileName)

            onProgress("Kodiere Kapitel \(trackNumber)/\(totalCount): \(markTitle)")

            var arguments = ["-y", "-i", item.url.path]
            if alreadyMP3 {
                arguments += ["-codec:a", "copy"]
            } else {
                arguments += ["-codec:a", "libmp3lame", "-qscale:a", String(settings.mp3Quality)]
            }
            arguments += [
                "-metadata", "title=\(markTitle)",
                "-metadata", "album=\(book.title)",
                "-metadata", "artist=\(book.author.isEmpty ? "Unbekannt" : book.author)",
                "-metadata", "track=\(trackNumber)/\(totalCount)",
                destination.path,
            ]
            try await FFmpegRunner.run(executable: ffmpeg, arguments: arguments)
        }

        // All chapters encoded: replace the old files, then drop old track
        // files this book no longer has (renamed/removed chapters).
        for fileName in finished {
            let target = outputDirectory.appendingPathComponent(fileName)
            let staged = staging.appendingPathComponent(fileName)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        }
        let keep = Set(finished)
        let trackPattern = try NSRegularExpression(pattern: #"^\d{2,3} - .*\.mp3$"#)
        for name in (try? fm.contentsOfDirectory(atPath: outputDirectory.path)) ?? [] where !keep.contains(name) {
            if trackPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                try? fm.removeItem(at: outputDirectory.appendingPathComponent(name))
            }
        }

        return outputDirectory
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}
