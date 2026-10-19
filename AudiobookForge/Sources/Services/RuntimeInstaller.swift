import CryptoKit
import Foundation

enum RuntimeType: String, Sendable, CaseIterable {
    case standalone = "Eigenständig (AudiobookForge)"
    case homebrew = "Homebrew / System"
    case mixed = "Gemischt"
    case missing = "Nicht eingerichtet"
}

struct RuntimeInstallProgress: Sendable {
    enum Phase: Sendable, Equatable {
        case idle
        case downloadingFFmpeg
        case extractingFFmpeg
        case downloadingPython
        case extractingPython
        case installingPackages
        case verifying
        case completed
        case failed(String)
    }

    let phase: Phase
    let bytesDownloaded: Int64
    let totalBytesExpected: Int64
    let fractionCompleted: Double
    let statusMessage: String

    init(phase: Phase, bytesDownloaded: Int64 = 0, totalBytesExpected: Int64 = 0, fractionCompleted: Double = 0.0, statusMessage: String = "") {
        self.phase = phase
        self.bytesDownloaded = bytesDownloaded
        self.totalBytesExpected = totalBytesExpected
        self.fractionCompleted = fractionCompleted
        self.statusMessage = statusMessage
    }
}

enum RuntimeInstallerError: LocalizedError, Sendable {
    case downloadFailed(String)
    case extractionFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case packageInstallFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason):
            return "Download fehlgeschlagen: \(reason)"
        case .extractionFailed(let reason):
            return "Entpacken fehlgeschlagen: \(reason)"
        case .checksumMismatch(let exp, let act):
            return "Prüfsummen-Fehler (SHA-256): erwartet \(exp), erhalten \(act)"
        case .packageInstallFailed(let reason):
            return "Paket-Installation fehlgeschlagen: \(reason)"
        case .cancelled:
            return "Vorgang abgebrochen."
        }
    }
}

final class RuntimeInstaller: @unchecked Sendable {
    static let shared = RuntimeInstaller()

    let runtimeDirectory: URL
    let pythonURL: URL
    let ffmpegURL: URL

    // Injectable downloader / URLSession for tests
    private let session: URLSession

    // Production release download URLs
    // Standalone Python: astral-sh python-build-standalone for aarch64-apple-darwin
    var pythonDownloadURL: URL = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20241016/cpython-3.11.10+20241016-aarch64-apple-darwin-install_only.tar.gz")!
    var pythonExpectedSHA256: String? = nil

    // FFmpeg static release for macOS arm64
    var ffmpegDownloadURL: URL = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip")!
    var ffmpegExpectedSHA256: String? = nil

    init(
        runtimeDirectory: URL = AppPaths.runtimeDirectory,
        session: URLSession = .shared
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.pythonURL = runtimeDirectory.appendingPathComponent("python/bin/python3")
        self.ffmpegURL = runtimeDirectory.appendingPathComponent("bin/ffmpeg")
        self.session = session
    }

    // MARK: - State Inspection

    var isStandalonePythonReady: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path)
    }

    var isStandaloneFFmpegReady: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegURL.path)
    }

    var isRuntimeReady: Bool {
        isStandalonePythonReady && isStandaloneFFmpegReady
    }

    var runtimeType: RuntimeType {
        let hasAppFFmpeg = isStandaloneFFmpegReady
        let hasAppPy = isStandalonePythonReady

        let hasSysFFmpeg = FFmpegLocator.resolve(settings: AppSettings()) != nil && !hasAppFFmpeg
        let hasSysPy = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3.12")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3.11")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3.12")

        if hasAppFFmpeg && hasAppPy {
            return .standalone
        } else if (hasAppFFmpeg || hasAppPy) && (hasSysFFmpeg || hasSysPy) {
            return .mixed
        } else if hasSysFFmpeg && hasSysPy {
            return .homebrew
        } else {
            return .missing
        }
    }

    var runtimeDirectorySizeBytes: Int64 {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: runtimeDirectory.path) else {
            return 0
        }
        var total: Int64 = 0
        for subpath in subpaths {
            let fullPath = runtimeDirectory.appendingPathComponent(subpath).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: - Installation Workflow

    func installAll(
        onProgress: @escaping @Sendable (RuntimeInstallProgress) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        // Step 1: FFmpeg
        if !isStandaloneFFmpegReady {
            try await installFFmpeg(onProgress: onProgress)
        } else {
            onProgress(RuntimeInstallProgress(phase: .extractingFFmpeg, fractionCompleted: 0.3, statusMessage: "ffmpeg ist bereits vorhanden."))
        }

        // Step 2: Standalone Python
        if !isStandalonePythonReady {
            try await installPython(onProgress: onProgress)
        } else {
            onProgress(RuntimeInstallProgress(phase: .extractingPython, fractionCompleted: 0.7, statusMessage: "Python ist bereits vorhanden."))
        }

        // Step 3: Verify and complete
        onProgress(RuntimeInstallProgress(phase: .verifying, fractionCompleted: 0.95, statusMessage: "Verifiziere Laufzeit …"))
        guard isStandaloneFFmpegReady && isStandalonePythonReady else {
            let msg = "Laufzeit unvollständig nach Installation."
            onProgress(RuntimeInstallProgress(phase: .failed(msg), fractionCompleted: 1.0, statusMessage: msg))
            throw RuntimeInstallerError.extractionFailed(msg)
        }

        onProgress(RuntimeInstallProgress(phase: .completed, fractionCompleted: 1.0, statusMessage: "AudiobookForge-Laufzeit ist einsatzbereit!"))
    }

    func installFFmpeg(
        onProgress: @escaping @Sendable (RuntimeInstallProgress) -> Void
    ) async throws {
        onProgress(RuntimeInstallProgress(phase: .downloadingFFmpeg, fractionCompleted: 0.05, statusMessage: "Lade ffmpeg herunter …"))

        let binDir = runtimeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let tempArchive = runtimeDirectory.appendingPathComponent("ffmpeg_download_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempArchive) }

        try await downloadFile(from: ffmpegDownloadURL, to: tempArchive, expectedSHA256: ffmpegExpectedSHA256) { bytes, total, frac in
            onProgress(RuntimeInstallProgress(
                phase: .downloadingFFmpeg,
                bytesDownloaded: bytes,
                totalBytesExpected: total,
                fractionCompleted: 0.05 + frac * 0.20,
                statusMessage: "Lade ffmpeg: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) von \(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "…")"
            ))
        }

        onProgress(RuntimeInstallProgress(phase: .extractingFFmpeg, fractionCompleted: 0.26, statusMessage: "Entpacke ffmpeg …"))

        // Detect archive type or binary
        if ffmpegDownloadURL.pathExtension.lowercased() == "zip" {
            let extractDir = runtimeDirectory.appendingPathComponent("ffmpeg_extracted_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let unzipRes = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-q", "-o", tempArchive.path, "-d", extractDir.path])
            if unzipRes.terminationStatus != 0 {
                throw RuntimeInstallerError.extractionFailed("unzip beendet mit Fehler: \(unzipRes.standardErrorText)")
            }

            // Find ffmpeg binary in extracted contents
            if let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: extractDir.path) {
                for subpath in subpaths where subpath.hasSuffix("ffmpeg") && !subpath.contains("/") {
                    let fileURL = extractDir.appendingPathComponent(subpath)
                    if FileManager.default.fileExists(atPath: ffmpegURL.path) {
                        try? FileManager.default.removeItem(at: ffmpegURL)
                    }
                    try FileManager.default.copyItem(at: fileURL, to: ffmpegURL)
                    break
                }
            }
        } else {
            // Assume direct binary or tar.gz
            if FileManager.default.fileExists(atPath: ffmpegURL.path) {
                try? FileManager.default.removeItem(at: ffmpegURL)
            }
            try FileManager.default.copyItem(at: tempArchive, to: ffmpegURL)
        }

        // Set permissions 0755
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegURL.path)
        // Strip quarantine
        _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-d", "com.apple.quarantine", ffmpegURL.path])

        onProgress(RuntimeInstallProgress(phase: .extractingFFmpeg, fractionCompleted: 0.30, statusMessage: "ffmpeg erfolgreich eingerichtet."))
    }

    func installPython(
        onProgress: @escaping @Sendable (RuntimeInstallProgress) -> Void
    ) async throws {
        onProgress(RuntimeInstallProgress(phase: .downloadingPython, fractionCompleted: 0.32, statusMessage: "Lade eigenständiges Python 3.11 herunter …"))

        let tempArchive = runtimeDirectory.appendingPathComponent("python_download_\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: tempArchive) }

        try await downloadFile(from: pythonDownloadURL, to: tempArchive, expectedSHA256: pythonExpectedSHA256) { bytes, total, frac in
            onProgress(RuntimeInstallProgress(
                phase: .downloadingPython,
                bytesDownloaded: bytes,
                totalBytesExpected: total,
                fractionCompleted: 0.32 + frac * 0.38,
                statusMessage: "Lade Python: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) von \(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "…")"
            ))
        }

        onProgress(RuntimeInstallProgress(phase: .extractingPython, fractionCompleted: 0.72, statusMessage: "Entpacke Python …"))

        let pythonTargetDir = runtimeDirectory.appendingPathComponent("python", isDirectory: true)
        if FileManager.default.fileExists(atPath: pythonTargetDir.path) {
            try? FileManager.default.removeItem(at: pythonTargetDir)
        }
        try FileManager.default.createDirectory(at: pythonTargetDir, withIntermediateDirectories: true)

        let tarRes = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", tempArchive.path, "-C", pythonTargetDir.path, "--strip-components=1"]
        )
        if tarRes.terminationStatus != 0 {
            // Retry without strip-components if archive layout differs
            _ = try? await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", tempArchive.path, "-C", pythonTargetDir.path]
            )
        }

        // Set permissions and clear quarantine
        if FileManager.default.fileExists(atPath: pythonURL.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonURL.path)
            _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-d", "com.apple.quarantine", pythonURL.path])
        }

        onProgress(RuntimeInstallProgress(phase: .extractingPython, fractionCompleted: 0.85, statusMessage: "Python erfolgreich entpackt."))
    }

    func removeRuntime() throws {
        if FileManager.default.fileExists(atPath: runtimeDirectory.path) {
            try FileManager.default.removeItem(at: runtimeDirectory)
        }
    }

    // MARK: - Download Engine

    private func downloadFile(
        from url: URL,
        to destination: URL,
        expectedSHA256: String?,
        onProgress: @escaping @Sendable (Int64, Int64, Double) -> Void
    ) async throws {
        if url.isFileURL {
            // Local file copy for unit tests / offline mock
            let data = try Data(contentsOf: url)
            if let expected = expectedSHA256 {
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual.lowercased() == expected.lowercased() else {
                    throw RuntimeInstallerError.checksumMismatch(expected: expected, actual: actual)
                }
            }
            try data.write(to: destination)
            onProgress(Int64(data.count), Int64(data.count), 1.0)
            return
        }

        // Network download with streaming & hash calculation
        let (bytes, response) = try await session.bytes(from: url)
        let totalExpected = response.expectedContentLength
        var downloaded: Int64 = 0
        var hasher = SHA256()

        let tempPart = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: tempPart.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempPart) else {
            throw RuntimeInstallerError.downloadFailed("Konnte temporäre Datei nicht öffnen: \(tempPart.path)")
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(65536)

        for try await byte in bytes {
            buffer.append(byte)
            downloaded += 1

            if buffer.count >= 65536 {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)

                let fraction = totalExpected > 0 ? min(1.0, Double(downloaded) / Double(totalExpected)) : 0.0
                onProgress(downloaded, totalExpected, fraction)
            }
        }

        if !buffer.isEmpty {
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
        }

        let actualSHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = expectedSHA256 {
            guard actualSHA256.lowercased() == expected.lowercased() else {
                try? FileManager.default.removeItem(at: tempPart)
                throw RuntimeInstallerError.checksumMismatch(expected: expected, actual: actualSHA256)
            }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempPart, to: destination)
        onProgress(downloaded, totalExpected, 1.0)
    }
}
