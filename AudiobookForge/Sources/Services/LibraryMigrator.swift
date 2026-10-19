import Foundation
import OSLog

/// One-time migration of the v2 single-file `library.json` into the v3
/// per-book layout (plan 5.1). Runs at app start — never under XCTest
/// (guard at the call site in `AudiobookForgeApp`).
///
/// Safety: the v2 file is backed up FIRST (`library.json.v2.bak`, kept
/// permanently, plus a dated copy in `backups/<ISO-Datum>/`), each book is
/// written atomically (temp directory + rename), and the v2 file is only
/// removed after `index.json` has been written successfully. On any
/// failure the partially created `library/` tree is removed and the app
/// keeps running on the untouched v2 data.
enum LibraryMigrator {
    private static let logger = Logger(subsystem: "com.pymolt.AudiobookForge", category: "library-migration")

    enum MigrationResult: Equatable {
        case notNeeded
        case migrated(bookCount: Int)
        case failed(String)
    }

    struct MigrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Migrates when a v2 `library.json` exists and no v3 index does.
    /// Idempotent: a second call is a no-op once `index.json` exists.
    static func migrateIfNeeded(root: URL) -> MigrationResult {
        guard FileManager.default.fileExists(atPath: LibraryLayout.legacyLibraryURL(root).path) else {
            return .notNeeded
        }
        guard !LibraryLayout.hasV3Index(root) else { return .notNeeded }
        do {
            let count = try migrate(root: root)
            return .migrated(bookCount: count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Test hook: `abortAfterBooks` throws after that many books were
    /// written, simulating a crash mid-migration (the v2 file must remain
    /// unchanged in that case).
    @discardableResult
    static func migrate(root: URL, abortAfterBooks: Int? = nil) throws -> Int {
        let fileManager = FileManager.default
        let legacyURL = LibraryLayout.legacyLibraryURL(root)
        let indexURL = LibraryLayout.indexURL(root)

        guard fileManager.fileExists(atPath: legacyURL.path) else { return 0 }
        guard !fileManager.fileExists(atPath: indexURL.path) else { return 0 }

        let books: [BookProject]
        do {
            let data = try Data(contentsOf: legacyURL)
            books = try JSONDecoder().decode([BookProject].self, from: data)
        } catch {
            throw MigrationError(message: "v2-Bibliothek konnte nicht gelesen werden: \(error.localizedDescription)")
        }

        // Backup BEFORE anything is written: a permanent .bak next to the
        // v2 file plus a dated copy in backups/.
        do {
            if fileManager.fileExists(atPath: LibraryLayout.legacyBackupURL(root).path) {
                try fileManager.removeItem(at: LibraryLayout.legacyBackupURL(root))
            }
            try fileManager.copyItem(at: legacyURL, to: LibraryLayout.legacyBackupURL(root))
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withFullDate]
            let datedDirectory = root.appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(dateFormatter.string(from: Date()), isDirectory: true)
            try fileManager.createDirectory(at: datedDirectory, withIntermediateDirectories: true)
            let datedCopy = datedDirectory.appendingPathComponent("library.json")
            if fileManager.fileExists(atPath: datedCopy.path) {
                try fileManager.removeItem(at: datedCopy)
            }
            try fileManager.copyItem(at: legacyURL, to: datedCopy)
        } catch {
            throw MigrationError(message: "Backup der v2-Bibliothek fehlgeschlagen: \(error.localizedDescription)")
        }

        do {
            try fileManager.createDirectory(at: LibraryLayout.booksRoot(root), withIntermediateDirectories: true)
            for (index, book) in books.enumerated() {
                if let abortAfterBooks, index >= abortAfterBooks {
                    throw MigrationError(message: "Migration abgebrochen (Test/Abbruch nach \(abortAfterBooks) Büchern).")
                }
                try writeBookAtomically(book, root: root)
                try LibraryLayout.writeCoverFiles(book, root: root)
            }

            let index = LibraryLayout.LibraryIndex(
                schemaVersion: LibraryLayout.schemaVersion,
                books: books.map { LibraryLayout.indexEntry(for: $0, root: root) }
            )
            try LibraryLayout.encodeIndex(index).write(to: indexURL, options: .atomic)

            // index.json exists → the v3 library is authoritative. The v2
            // file is no longer needed; its backup stays forever.
            try? fileManager.removeItem(at: legacyURL)
            logger.info("Bibliothek auf v3 umgestellt: \(books.count) Bücher, Backup unter library.json.v2.bak")
            return books.count
        } catch {
            // Rollback: the v2 file was never modified, so dropping the
            // partial v3 tree restores the exact pre-migration state.
            try? fileManager.removeItem(at: LibraryLayout.libraryRoot(root))
            logger.error("Migration fehlgeschlagen, v2-Daten unverändert: \(error.localizedDescription)")
            throw MigrationError(message: error.localizedDescription)
        }
    }

    /// Writes one book's files into a temporary directory first, then
    /// swaps it into place with a single rename — a book directory on
    /// disk is either fully old or fully new, never half-written.
    private static func writeBookAtomically(_ book: BookProject, root: URL) throws {
        let fileManager = FileManager.default
        let stagingRoot = root.appendingPathComponent(".migration-tmp-\(book.id.uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: stagingRoot)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        try LibraryLayout.writeBook(book, root: stagingRoot)

        let stagedDirectory = LibraryLayout.bookDirectory(stagingRoot, bookID: book.id)
        let destination = LibraryLayout.bookDirectory(root, bookID: book.id)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedDirectory, to: destination)
    }
}
