import Foundation
import AVFoundation

struct MP4ChapterPackager: ChapterPackager {
    let settings: AppSettings
    let format: OutputFormat // .m4b or .m4a

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
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookForge-mux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        onProgress("Ermittle Kapitellängen …")
        var chapterMarks: [(title: String, startMs: Int, endMs: Int)] = []
        var cursorMs = 0
        for item in ordered {
            let durationSeconds = try await audioDurationSeconds(url: item.url)
            let durationMs = Int((durationSeconds * 1000).rounded())
            chapterMarks.append((title: item.chapter.title, startMs: cursorMs, endMs: cursorMs + durationMs))
            cursorMs += durationMs
        }

        let concatListURL = workDir.appendingPathComponent("concat.txt")
        let concatContent = ordered.map { "file '\($0.url.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try concatContent.write(to: concatListURL, atomically: true, encoding: .utf8)

        let metadataURL = workDir.appendingPathComponent("ffmetadata.txt")
        try buildFFMetadata(book: book, chapters: chapterMarks).write(to: metadataURL, atomically: true, encoding: .utf8)

        let outputURL = outputDirectory.appendingPathComponent("\(sanitize(book.title)).\(format.fileExtension)")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        onProgress("Muxe finale \(format.fileExtension.uppercased())-Datei …")

        // Chapters now arrive pre-encoded as AAC (.m4a) matching the book's
        // settings, so the mux is a pure stream copy — no full re-read and
        // re-encode of the book's audio. Only legacy/foreign inputs (e.g.
        // MP3 chapters after a format switch) still get transcoded.
        let chapterCodec = ordered.first?.url.pathExtension.lowercased() == "m4a" ? "copy" : "aac"

        var arguments = [
            "-y",
            "-f", "concat", "-safe", "0", "-i", concatListURL.path,
            "-i", metadataURL.path,
        ]

        var coverImageURL: URL?
        if let coverData = book.coverImageData {
            let coverURL = workDir.appendingPathComponent("cover.jpg")
            try coverData.write(to: coverURL)
            coverImageURL = coverURL
            arguments += ["-i", coverURL.path]
        }

        arguments += ["-map_metadata", "1", "-map_chapters", "1", "-map", "0:a"]
        if coverImageURL != nil {
            arguments += ["-map", "2:v", "-c:v", "mjpeg", "-disposition:v", "attached_pic"]
        }
        arguments += ["-c:a", chapterCodec]
        if chapterCodec == "aac" {
            arguments += ["-b:a", "\(settings.aacBitrateKbps)k"]
        }
        arguments += ["-f", "ipod", outputURL.path]

        try await FFmpegRunner.run(executable: ffmpeg, arguments: arguments)

        return outputURL
    }

    private func audioDurationSeconds(url: URL) async throws -> Double {
        try await WaveFileInspector.durationSeconds(url: url)
    }

    private func buildFFMetadata(book: BookProject, chapters: [(title: String, startMs: Int, endMs: Int)]) -> String {
        var lines = [";FFMETADATA1"]
        lines.append("title=\(escape(book.title))")
        if !book.author.isEmpty { lines.append("artist=\(escape(book.author))") }
        lines.append("album=\(escape(book.title))")
        if !book.narratorLabel.isEmpty { lines.append("composer=\(escape(book.narratorLabel))") }
        if !book.sourceNote.isEmpty { lines.append("comment=\(escape(book.sourceNote))") }

        for chapter in chapters {
            lines.append("")
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(chapter.startMs)")
            lines.append("END=\(chapter.endMs)")
            lines.append("title=\(escape(chapter.title))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "\n", with: "\\\n")
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Audiobook" : cleaned
    }
}
