import Foundation

/// One installable, removable piece of an engine (v4.2): its runtime, a
/// language model, a voice or a Neural Engine export. The voice gallery
/// installs the pieces a voice needs; "Engines & Downloads" lists them all
/// with size and lets them be removed.
struct EngineComponent: Identifiable, Sendable {
    enum Kind: Sendable { case runtime, model, voice, neural }
    typealias Action = @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void

    let id: String
    let kind: Kind
    let title: String
    let installed: Bool
    /// On disk when installed, otherwise the expected download.
    let sizeBytes: Int64
    /// Gated Hugging Face repo: needs a sign-in and accepted terms.
    var gatedRepo: String? = nil
    /// Engines that use this piece too (the shared MLX runtime).
    var sharedBy: [TTSEngineID] = []
    var install: Action? = nil
    var remove: (@Sendable () throws -> Void)? = nil

    var sizeText: String { (installed ? "" : "~") + ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

/// An engine with its pieces and installed runtime version.
struct EngineStatus: Identifiable, Sendable {
    let engine: TTSEngineID
    let version: String?
    let components: [EngineComponent]
    var id: TTSEngineID { engine }
    /// Space of this engine's own pieces; a runtime shared with other
    /// engines (MLX) is listed but not counted, else it would appear five times.
    var installedBytes: Int64 { components.filter { $0.installed && $0.sharedBy.isEmpty }.reduce(0) { $0 + $1.sizeBytes } }
    var usesSharedRuntime: Bool { components.contains { !$0.sharedBy.isEmpty } }
    var installedCount: Int { components.filter(\.installed).count }
    /// Usable: runtime there and at least one model/voice (or nothing to install).
    var isReady: Bool {
        let runtimeOK = components.filter { $0.kind == .runtime }.allSatisfy(\.installed)
        let payload = components.filter { $0.kind == .model || $0.kind == .voice }
        return runtimeOK && (payload.isEmpty || payload.contains(where: \.installed))
    }
}

/// Disk probes run off the main thread; everything here is synchronous.
enum EngineInventory {
    static let mlxEngines: [TTSEngineID] = [.kokoro, .kokoroGerman, .kokoroThorsten, .supertonic3, .omniVoice]
    static var userHubCache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Display order: the app's main engines first, system voices last.
    static let displayOrder: [TTSEngineID] = [.phonon, .pocketTTS, .kokoro, .kokoroGerman, .kokoroThorsten, .piper, .supertonic3, .omniVoice, .appleSystem]

    static func all(settings: AppSettings) -> [EngineStatus] {
        let order = displayOrder + TTSEngineID.allCases.filter { !displayOrder.contains($0) }
        return order.map { status(of: $0, settings: settings) }
    }

    /// What still has to be installed before `voice` can speak — in order.
    static func missingComponents(for voice: VoiceID, settings: AppSettings) -> [EngineComponent] {
        let components = status(of: voice.engine, settings: settings).components
        return requiredComponentIDs(for: voice, settings: settings).compactMap { id in
            components.first { $0.id == id && !$0.installed }
        }
    }

    /// Ids of the pieces a voice needs (testable without disk access).
    static func requiredComponentIDs(for voice: VoiceID, settings: AppSettings) -> [String] {
        switch voice.engine {
        case .phonon:
            let language = PhononEngine.split(voice.voice).language
            return ["phonon.runtime", "phonon.model.\(PhononEnvironmentManager.modelKey(language: language, english31m: settings.phononEnglish31m))"]
        case .pocketTTS:
            let language = PhononEngine.split(voice.voice).language
            return ["pocket.runtime", "pocket.model.\(language)"] + (settings.pocketHighQuality ? ["pocket.model.\(language).24l"] : [])
        case .kokoro:
            return ["mlx.runtime", "kokoro.weights"]
        case .kokoroGerman, .kokoroThorsten:
            return ["mlx.runtime", "kokoroGerman.\(voice.voice)"]
        case .piper:
            return ["piper.runtime", "piper.voice.\(PiperEnvironmentManager.baseVoiceID(voice.voice))"]
        case .supertonic3:
            return ["mlx.runtime", "supertonic.model"]
        case .omniVoice:
            return ["mlx.runtime", "omnivoice.model"]
        case .appleSystem:
            return []
        }
    }

    static func status(of engine: TTSEngineID, settings: AppSettings) -> EngineStatus {
        switch engine {
        case .phonon: return phonon()
        case .pocketTTS: return pocket()
        case .kokoro: return EngineStatus(engine: engine, version: mlxVersion, components: [mlxRuntime(), kokoroWeights(settings)])
        case .kokoroGerman: return EngineStatus(engine: engine, version: mlxVersion, components: [mlxRuntime()] + ["martin", "victoria"].map(germanKokoro))
        case .kokoroThorsten: return EngineStatus(engine: engine, version: mlxVersion, components: [mlxRuntime(), germanKokoro("thorsten")])
        case .piper: return piper()
        case .supertonic3: return EngineStatus(engine: engine, version: mlxVersion, components: [mlxRuntime(), supertonic()])
        case .omniVoice: return EngineStatus(engine: engine, version: mlxVersion, components: [mlxRuntime(), omniVoice()])
        case .appleSystem:
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return EngineStatus(engine: engine, version: "macOS \(version.majorVersion).\(version.minorVersion)", components: [])
        }
    }

    // MARK: Phonon

    private static func phonon() -> EngineStatus {
        let env = PhononEnvironmentManager.shared
        var components = [EngineComponent(
            id: "phonon.runtime", kind: .runtime, title: L("Laufzeit (ptts)"), installed: env.isEnvironmentReady(),
            sizeBytes: size(of: env.directory, estimate: 100_000_000),
            install: { onLine in try await env.setupEnvironment(onOutput: onLine) },
            remove: { try removeIfPresent(env.directory) })]
        for language in PhononEnvironmentManager.models {
            let installed = env.isModelReady(language)
            let base = languageDisplayName(PhononEnvironmentManager.language(ofModel: language))
            components.append(EngineComponent(
                id: "phonon.model.\(language)", kind: .model,
                title: language.hasSuffix("-31m") ? String(format: L("%@ · 31M-Modell mit Stimmen (Apache 2.0)"), base) : String(format: L("%@ · Sprachmodell mit Stimmen"), base),
                installed: installed, sizeBytes: installed ? env.modelSizeOnDisk(language) - size(of: env.neuralDirectory(for: language), estimate: 0) : (language.hasSuffix("-31m") ? 66_000_000 : 80_000_000),
                gatedRepo: PhononEnvironmentManager.isGated(language) ? PhononEnvironmentManager.repo(for: language) : nil,
                install: { onLine in try await env.installModel(language, onOutput: onLine) },
                remove: { try env.removeModel(language) }))
            if installed {
                components.append(EngineComponent(
                    id: "phonon.neural.\(language)", kind: .neural,
                    title: String(format: L("%@ · Neural Engine (Stromsparmodus)"), base + (language.hasSuffix("-31m") ? " 31M" : "")),
                    installed: env.isNeuralReady(language), sizeBytes: size(of: env.neuralDirectory(for: language), estimate: 195_000_000),
                    install: { onLine in try await env.prepareNeuralEngine(language, onOutput: onLine) },
                    remove: { try env.removeNeural(language) }))
            }
        }
        return EngineStatus(engine: .phonon, version: pythonPackageVersion("ptts", venv: env.directory), components: components)
    }

    // MARK: Pocket TTS

    private static func pocket() -> EngineStatus {
        let env = PocketEnvironmentManager.shared
        var components = [EngineComponent(
            id: "pocket.runtime", kind: .runtime, title: L("Laufzeit (pocket-tts, PyTorch)"), installed: env.isEnvironmentReady(),
            sizeBytes: size(of: env.directory, estimate: 950_000_000),
            install: { onLine in try await env.setupEnvironment(onOutput: onLine) },
            remove: { try removeIfPresent(env.directory) })]
        for language in PocketEnvironmentManager.languages {
            for high in [false, true] {
                let installed = env.isModelReady(language, highQuality: high)
                let resolved = env.modelDirectories(language, highQuality: high).reduce(Int64(0)) { $0 + HFCacheJanitor.resolvedSize(of: $1) }
                components.append(EngineComponent(
                    id: "pocket.model.\(language)" + (high ? ".24l" : ""), kind: .model,
                    title: languageDisplayName(language) + " · " + (high ? L("Hohe Qualität (24 Schichten)") : L("Sprachmodell mit Stimmen")),
                    installed: installed, sizeBytes: installed && resolved > 0 ? resolved : (high ? 700_000_000 : 220_000_000),
                    gatedRepo: PocketEnvironmentManager.repo,
                    install: { onLine in try await env.installModel(language, highQuality: high, onOutput: onLine) },
                    remove: { try env.removeModel(language, highQuality: high) }))
            }
        }
        return EngineStatus(engine: .pocketTTS, version: pythonPackageVersion("pocket_tts", venv: env.directory), components: components)
    }

    // MARK: MLX engines (Kokoro, Kokoro German, Supertonic, OmniVoice)

    private static var mlxVersion: String? { pythonPackageVersion("mlx_audio", venv: BridgeEnvironmentManager.shared.bridgeDirectory) }

    private static func mlxRuntime() -> EngineComponent {
        let bridge = BridgeEnvironmentManager.shared
        return EngineComponent(
            id: "mlx.runtime", kind: .runtime, title: L("MLX-Laufzeit (mlx-audio)"), installed: bridge.isEnvironmentReady(),
            sizeBytes: size(of: bridge.bridgeDirectory, estimate: 1_400_000_000), sharedBy: mlxEngines,
            install: { onLine in try await bridge.runSetup(onOutput: onLine) },
            remove: { try removeIfPresent(bridge.bridgeDirectory) })
    }

    private static func kokoroWeights(_ settings: AppSettings) -> EngineComponent {
        let repo = settings.kokoroModelRepo.isEmpty ? "mlx-community/Kokoro-82M-bf16" : settings.kokoroModelRepo
        let hub = userHubCache
        let repoDir = HFCacheJanitor.repoDirectory(repo, hubRoot: hub)
        let snapshots = (try? FileManager.default.contentsOfDirectory(at: repoDir.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil)) ?? []
        let installed = snapshots.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
        return EngineComponent(
            id: "kokoro.weights", kind: .model, title: L("Modell (EN, FR, ES, IT, alle Stimmen)"), installed: installed,
            sizeBytes: installed ? HFCacheJanitor.resolvedSize(of: repoDir.appendingPathComponent("snapshots")) : 340_000_000,
            install: { onLine in
                let bridge = BridgeEnvironmentManager.shared
                let status = try await ScriptRunner.run(
                    executable: bridge.pythonExecutableURL,
                    arguments: ["-c", "from huggingface_hub import snapshot_download; snapshot_download(repo_id='\(repo)'); print('DONE')"],
                    environment: HuggingFaceAccount.processEnvironment(), onLine: onLine)
                guard status == 0 else { throw BridgeEnvironmentError.setupFailed(exitCode: status) }
            },
            remove: { try HFCacheJanitor.removeRepo(repo, hubRoot: hub) })
    }

    private static func germanKokoro(_ voice: String) -> EngineComponent {
        let manager = GermanKokoroEnvironmentManager.shared
        return EngineComponent(
            id: "kokoroGerman.\(voice)", kind: .voice, title: String(format: L("Stimme %@"), voice.capitalized),
            installed: manager.isVoiceReady(voice), sizeBytes: size(of: manager.modelDirectory(for: voice), estimate: 315_000_000),
            install: { onLine in try await manager.install(voice, onOutput: onLine) },
            remove: { try removeIfPresent(manager.modelDirectory(for: voice)) })
    }

    private static func supertonic() -> EngineComponent {
        let manager = SupertonicEnvironmentManager.shared
        let installedBytes = size(of: manager.modelDirectory, estimate: 0) + size(of: manager.runtimeDirectory, estimate: 0)
        return EngineComponent(
            id: "supertonic.model", kind: .model, title: L("Modell und Laufzeit"), installed: manager.isReady(),
            sizeBytes: installedBytes > 0 ? installedBytes : 400_000_000,
            install: { onLine in try await manager.install(onOutput: onLine) },
            remove: { try removeIfPresent(manager.modelDirectory); try removeIfPresent(manager.runtimeDirectory) })
    }

    private static func omniVoice() -> EngineComponent {
        let manager = OmniVoiceEnvironmentManager.shared
        let directory = manager.modelDirectory()
        let hub = userHubCache.resolvingSymlinksInPath().path
        var remove: (@Sendable () throws -> Void)?
        if let directory {
            let path = directory.resolvingSymlinksInPath().path
            if path.hasPrefix(AppPaths.modelsDirectory.resolvingSymlinksInPath().path) {
                remove = { try removeIfPresent(directory) }
            } else if path.hasPrefix(hub) {
                remove = { try HFCacheJanitor.removeRepo("mlx-community/OmniVoice-bfloat16", hubRoot: userHubCache) }
            } // LM Studio's folder belongs to LM Studio: not removed from here.
        }
        return EngineComponent(
            id: "omnivoice.model", kind: .model, title: L("Modell (bfloat16)"), installed: directory != nil,
            sizeBytes: directory.map { HFCacheJanitor.resolvedSize(of: $0) } ?? 2_040_000_000,
            install: { onLine in
                let models = ModelManager()
                guard let item = models.availableModels.first(where: { $0.id == "omnivoice-base" }) else { return }
                try await models.install(item, onOutput: onLine)
            },
            remove: remove)
    }

    // MARK: Piper

    private static func piper() -> EngineStatus {
        let env = PiperEnvironmentManager.shared
        var components = [EngineComponent(
            id: "piper.runtime", kind: .runtime, title: L("Laufzeit (piper-tts)"), installed: env.isEnvironmentReady(),
            sizeBytes: size(of: env.directory, estimate: 250_000_000),
            install: { onLine in try await env.runSetup(onOutput: onLine) },
            remove: {
                // The runtime folder also holds the voices: keep them.
                let fm = FileManager.default
                for item in (try? fm.contentsOfDirectory(at: env.directory, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent != "voices" {
                    try fm.removeItem(at: item)
                }
            })]
        for voice in PiperVoiceCatalog.allVoices {
            let installed = env.isVoiceDownloaded(voice.id)
            components.append(EngineComponent(
                id: "piper.voice.\(voice.id)", kind: .voice, title: voice.displayName, installed: installed,
                sizeBytes: installed ? fileSize(env.onnxURL(for: voice.id)) + fileSize(env.onnxConfigURL(for: voice.id)) : piperEstimate(voice.id),
                install: { onLine in try await env.downloadVoice(voice) { fraction in onLine(String(format: "PROGRESS %.2f", fraction)) } },
                remove: { try removeIfPresent(env.onnxURL(for: voice.id)); try removeIfPresent(env.onnxConfigURL(for: voice.id)) }))
        }
        return EngineStatus(engine: .piper, version: pythonPackageVersion("piper_tts", venv: env.directory), components: components)
    }

    static func piperEstimate(_ id: String) -> Int64 {
        if id.contains("emotional") { return 77_000_000 }
        if id.hasSuffix("-high") { return 115_000_000 }
        if id.hasSuffix("-x_low") { return 28_000_000 }
        return 63_000_000
    }

    // MARK: Helpers

    /// Version of an installed Python package in a venv (`<name>-<version>.dist-info`).
    static func pythonPackageVersion(_ name: String, venv: URL) -> String? {
        let fm = FileManager.default
        let lib = venv.appendingPathComponent(".venv/lib")
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "_")
        for python in (try? fm.contentsOfDirectory(atPath: lib.path)) ?? [] {
            let site = lib.appendingPathComponent("\(python)/site-packages")
            for entry in (try? fm.contentsOfDirectory(atPath: site.path)) ?? [] where entry.hasSuffix(".dist-info") {
                let stem = String(entry.dropLast(".dist-info".count))
                guard let dash = stem.lastIndex(of: "-") else { continue }
                if stem[..<dash].lowercased().replacingOccurrences(of: "-", with: "_") == normalized {
                    return String(stem[stem.index(after: dash)...])
                }
            }
        }
        return nil
    }

    private static func size(of url: URL, estimate: Int64) -> Int64 {
        FileManager.default.fileExists(atPath: url.path) ? StorageReportService.directorySize(at: url) : estimate
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
