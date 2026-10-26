import Foundation

final class SupertonicEnvironmentManager: @unchecked Sendable {
    static let shared = SupertonicEnvironmentManager()

    let modelDirectory = AppPaths.applicationSupportDirectory.appendingPathComponent("models/supertonic-3-mlx", isDirectory: true)
    let runtimeDirectory = AppPaths.applicationSupportDirectory.appendingPathComponent("models/supertonic-mlx-runtime", isDirectory: true)

    private init() {}

    func isReady() -> Bool {
        let fm = FileManager.default
        return BridgeEnvironmentManager.shared.isEnvironmentReady()
            && fm.fileExists(atPath: modelDirectory.appendingPathComponent("tts.json").path)
            && fm.fileExists(atPath: modelDirectory.appendingPathComponent("weights/vocoder.npz").path)
            && fm.fileExists(atPath: runtimeDirectory.appendingPathComponent("supertonic_mlx/__init__.py").path)
    }

    func install(onOutput: @escaping @Sendable (String) -> Void) async throws {
        let bridge = BridgeEnvironmentManager.shared
        guard bridge.isEnvironmentReady() else {
            throw TTSEngineError.notReady(L("Kokoro-MLX-Umgebung zuerst unter Einstellungen → Engines & Downloads einrichten."))
        }
        guard let script = Bundle.main.url(forResource: "setup_supertonic_mlx", withExtension: "py", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "setup_supertonic_mlx", withExtension: "py") else {
            throw BridgeEnvironmentError.resourcesMissing
        }
        try await FFmpegRunner.run(executable: bridge.pythonExecutableURL, arguments: [
            script.path,
            "--model-dir", modelDirectory.path,
            "--runtime-dir", runtimeDirectory.path,
        ], onOutput: onOutput)
        guard isReady() else {
            throw TTSEngineError.notReady("Supertonic-Modell oder MLX-Laufzeit fehlen nach der Installation.")
        }
    }
}
