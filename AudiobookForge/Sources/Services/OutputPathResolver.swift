import Foundation

enum OutputPathResolver {
    /// Resolves the final output directory for a book, appending a numeric
    /// suffix on collision so results never silently overwrite each other.
    static func resolveOutputDirectory(book: BookProject, settings: AppSettings) -> URL {
        // v4: a book that already has its own output folder (re-voicing,
        // regenerating) writes into it again — the staged packagers swap
        // the files in place instead of leaving "Titel (2)" copies behind.
        if let own = book.outputDirectoryURL, FileManager.default.fileExists(atPath: own.path) {
            return own
        }
        let base = URL(fileURLWithPath: settings.outputBaseFolderPath)
        let relative = settings.outputFolderTemplate.relativePath(title: book.title, author: book.author)
        var candidate = base.appendingPathComponent(relative, isDirectory: true)

        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent(relative + " (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
