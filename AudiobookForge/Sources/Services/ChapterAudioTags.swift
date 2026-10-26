import Foundation

/// ID3 tags of a book's MP3 chapters (v4.1). The pipeline registers them
/// before synthesis, so the chapter encoder writes them on the first and
/// only encode; packaging then just MOVES the tagged files into the
/// output folder instead of copying every byte again.
struct ChapterTag: Sendable, Equatable {
    var title: String
    var album: String
    var artist: String
    var track: Int
    var total: Int

    var ffmpegArguments: [String] {
        ["-metadata", "title=\(title)", "-metadata", "album=\(album)",
         "-metadata", "artist=\(artist)", "-metadata", "track=\(track)/\(total)"]
    }
}

enum ChapterAudioTags {
    private static let registry = LockedBox<[String: ChapterTag]>([:])

    /// Tags for the chapters as the packager will order and name them:
    /// the narrated chapters sorted by order, mark titles from
    /// `ChapterNaming` ("Gruppe — Titel").
    static func tags(for book: BookProject, narrated chapters: [Chapter]) -> [UUID: ChapterTag] {
        let ordered = chapters.sorted { $0.order < $1.order }
        let titles = ChapterNaming.markTitles(for: ordered)
        var result: [UUID: ChapterTag] = [:]
        for (index, chapter) in ordered.enumerated() {
            result[chapter.id] = ChapterTag(title: titles[index], album: book.title,
                                            artist: book.author.isEmpty ? "Unbekannt" : book.author,
                                            track: index + 1, total: ordered.count)
        }
        return result
    }

    static func register(_ tags: [URL: ChapterTag]) {
        registry.withLock { current in
            for (url, tag) in tags { current[url.standardizedFileURL.path] = tag }
        }
    }

    static func unregister(_ urls: [URL]) {
        registry.withLock { current in
            for url in urls { current[url.standardizedFileURL.path] = nil }
        }
    }

    static func tag(for url: URL) -> ChapterTag? {
        registry.withLock { $0[url.standardizedFileURL.path] }
    }

    /// Reads title/album/artist/track of an audio file with ffprobe.
    static func readTag(of url: URL, ffprobe: URL) async -> ChapterTag? {
        guard let result = try? await ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "format_tags=title,album,artist,track", "-of", "json", url.path,
        ]), result.terminationStatus == 0,
            let json = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
            let format = json["format"] as? [String: Any],
            let tags = format["tags"] as? [String: String] else { return nil }
        let lowered = Dictionary(tags.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let trackParts = (lowered["track"] ?? "").split(separator: "/").compactMap { Int($0) }
        guard let title = lowered["title"], let album = lowered["album"], trackParts.count == 2 else { return nil }
        return ChapterTag(title: title, album: album, artist: lowered["artist"] ?? "", track: trackParts[0], total: trackParts[1])
    }
}
