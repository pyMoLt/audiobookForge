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
        guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settings) else { throw PackagerError.ffmpegNotFound }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let ordered = chapterAudioFiles.sorted { $0.chapter.order < $1.chapter.order }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookForge-mux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        onProgress("Ermittle Kapitellängen …")
        // Plan 7.3: mark names come from title+groupTitle ("Gruppe — Titel",
        // shortened from 70 characters, deduplicated) — never the raw fields.
        let markTitles = ChapterNaming.markTitles(for: ordered.map(\.chapter))
        var chapterMarks: [(title: String, startMs: Int, endMs: Int)] = []
        var cursorMs = 0
        for (index, item) in ordered.enumerated() {
            // The chapter's known duration wins over re-measuring the file:
            // after a restore-cut from the packaged M4B, AVAsset bookkeeping
            // differs from the original file by a couple of AAC priming
            // frames, which would shift every later chapter mark.
            let durationSeconds: Double
            if let known = item.chapter.audioDurationSeconds {
                durationSeconds = known
            } else {
                durationSeconds = try await audioDurationSeconds(url: item.url)
            }
            let durationMs = Int((durationSeconds * 1000).rounded())
            chapterMarks.append((title: markTitles[index], startMs: cursorMs, endMs: cursorMs + durationMs))
            cursorMs += durationMs
        }

        let concatListURL = workDir.appendingPathComponent("concat.txt")
        let concatContent = ordered.map { "file '\($0.url.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try concatContent.write(to: concatListURL, atomically: true, encoding: .utf8)

        let metadataURL = workDir.appendingPathComponent("ffmetadata.txt")
        try buildFFMetadata(book: book, chapters: chapterMarks).write(to: metadataURL, atomically: true, encoding: .utf8)

        let outputURL = outputDirectory.appendingPathComponent("\(sanitize(book.title)).\(format.fileExtension)")
        // v4: mux into a staging file beside the target and swap it in only
        // once ffmpeg succeeded — the previous file stays intact on failure
        // (re-voicing, cancelled runs) and may itself be a mux source
        // (chapters restore-cut from the packaged book).
        let stagingURL = outputDirectory.appendingPathComponent(".abf-staging-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

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
        arguments += ["-f", "ipod", stagingURL.path]

        try await FFmpegRunner.run(executable: ffmpeg, arguments: arguments)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        }

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
