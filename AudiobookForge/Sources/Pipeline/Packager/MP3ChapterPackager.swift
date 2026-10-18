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
        guard let ffmpeg = FFmpegLocator.resolve(settings: settings) else { throw PackagerError.ffmpegNotFound }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let ordered = chapterAudioFiles.sorted { $0.chapter.order < $1.chapter.order }
        let totalCount = ordered.count
        // Chapters now arrive pre-encoded as MP3 matching the book's
        // quality setting, so packaging is a metadata-only stream copy.
        // Foreign inputs (e.g. AAC chapters after a format switch) are
        // still transcoded once.
        let alreadyMP3 = ordered.first?.url.pathExtension.lowercased() == "mp3"

        for (index, item) in ordered.enumerated() {
            let trackNumber = index + 1
            let fileName = String(format: "%02d - %@.mp3", trackNumber, sanitize(item.chapter.title))
            let destination = outputDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            onProgress("Kodiere Kapitel \(trackNumber)/\(totalCount): \(item.chapter.title)")

            var arguments = ["-y", "-i", item.url.path]
            if alreadyMP3 {
                arguments += ["-codec:a", "copy"]
            } else {
                arguments += ["-codec:a", "libmp3lame", "-qscale:a", String(settings.mp3Quality)]
            }
            arguments += [
                "-metadata", "title=\(item.chapter.title)",
                "-metadata", "album=\(book.title)",
                "-metadata", "artist=\(book.author.isEmpty ? "Unbekannt" : book.author)",
                "-metadata", "track=\(trackNumber)/\(totalCount)",
                destination.path,
            ]
            try await FFmpegRunner.run(executable: ffmpeg, arguments: arguments)
        }

        return outputDirectory
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}
