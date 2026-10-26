#if DEBUG
import Foundation

/// DEBUG-only (v4): renders the bundled voice samples with the real
/// engines — `abfcmd buildSamples=<dir>`; `scripts/build_voice_samples.sh`
/// copies the result into Resources/VoiceSamples. Small AAC (mono, 24 kHz,
/// 24 kbit/s); macOS system voices and own voices stay live.
enum VoiceSampleBuilder {
    static func build(into directory: URL, settings base: AppSettings, only engines: Set<TTSEngineID>? = nil) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("build.log")
        func log(_ line: String) {
            let entry = "\(Date()) \(line)\n"
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
            } else {
                try? entry.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
        var settings = base
        settings.chapterLeadInMs = 150
        settings.chapterTailMs = 250
        settings.loudnessNormalizationEnabled = false
        settings.audioEnhancementEnabled = false
        guard let ffmpeg = await FFmpegLocator.resolveAsync(settings: settings) else { log("ERROR kein ffmpeg"); return }

        let indexURL = directory.appendingPathComponent("voice_samples.json")
        var index = (try? JSONDecoder().decode([String: VoiceSampleLibrary.Entry].self, from: Data(contentsOf: indexURL))) ?? [:]
        let profiles = VoiceCatalog.allProfiles.filter {
            $0.id.engine != .appleSystem && !$0.id.voice.hasPrefix("clone:") && (engines?.contains($0.id.engine) ?? true)
        }
        log("START \(profiles.count) Stimmen")
        for profile in profiles {
            let key = VoiceSampleLibrary.key(profile.id)
            let file = VoiceSampleLibrary.fileName(profile.id)
            let target = directory.appendingPathComponent(file)
            if index[key]?.text == profile.sampleText, fm.fileExists(atPath: target.path) { continue }
            let engine = TTSEngineFactory.engine(for: profile.id.engine, settings: settings)
            // Piper voices are fetched just for their sample and removed
            // again, so building samples leaves no extra models behind.
            var temporaryPiperVoice = false
            if profile.id.engine == .piper, PiperEnvironmentManager.shared.isEnvironmentReady(),
               !PiperEnvironmentManager.shared.isVoiceDownloaded(profile.id.voice),
               let voice = PiperVoiceCatalog.voice(id: profile.id.voice) {
                temporaryPiperVoice = (try? await PiperEnvironmentManager.shared.downloadVoice(voice) { _ in }) != nil
            }
            defer {
                if temporaryPiperVoice {
                    try? fm.removeItem(at: PiperEnvironmentManager.shared.onnxURL(for: profile.id.voice))
                    try? fm.removeItem(at: PiperEnvironmentManager.shared.onnxConfigURL(for: profile.id.voice))
                }
            }
            guard await engine.isReady(voice: profile.id.voice) else { log("SKIP \(key) (nicht eingerichtet)"); continue }
            let temp = fm.temporaryDirectory.appendingPathComponent("abf-sample-\(UUID().uuidString).m4a")
            defer { try? fm.removeItem(at: temp) }
            do {
                _ = try await engine.synthesize(text: profile.sampleText, voice: profile.id.voice,
                                                speed: settings.defaultSpeed(for: profile.id.engine), outputURL: temp, onProgress: { _ in })
                try? fm.removeItem(at: target)
                try await FFmpegRunner.run(executable: ffmpeg, arguments: [
                    "-y", "-loglevel", "error", "-i", temp.path, "-ac", "1", "-ar", "24000",
                    "-c:a", "aac", "-b:a", "24k", "-map_metadata", "-1", target.path,
                ])
                index[key] = VoiceSampleLibrary.Entry(file: file, text: profile.sampleText)
                if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL) }
                log("OK \(key)")
            } catch {
                log("FAIL \(key): \(error.localizedDescription)")
            }
        }
        log("DONE \(index.count) Hörproben")
    }
}
#endif
