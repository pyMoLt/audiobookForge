import AVFoundation

/// Little 8-bit sounds (v4.3), synthesized in the app — no audio files and
/// nobody else's sounds. Quiet, short, and switched off with one setting.
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    enum Effect: CaseIterable {
        case bookDone, owlHoot, bark, achievement, retroDing, powerUp, pet
    }

    /// Mirrors `AppSettings.soundEffectsEnabled` (kept in sync by ContentView).
    var enabled = true

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var cache: [Effect: AVAudioPCMBuffer] = [:]
    private var started = false

    func play(_ effect: Effect) {
        guard enabled, !ProcessInfo.processInfo.isRunningTests else { return }
        guard let buffer = buffer(for: effect) else { return }
        do {
            if !started {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = 0.32
                try engine.start()
                started = true
            }
            player.scheduleBuffer(buffer, at: nil, options: [])
            if !player.isPlaying { player.play() }
        } catch {
            started = false
        }
    }

    private func buffer(for effect: Effect) -> AVAudioPCMBuffer? {
        if let cached = cache[effect] { return cached }
        let samples = Self.samples(for: effect)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        cache[effect] = buffer
        return buffer
    }

    // MARK: Synthesis

    private struct Note {
        var frequency: Double
        var duration: Double
        var wave: Wave = .square
        var glideTo: Double? = nil
        var vibrato: Double = 0
    }

    private enum Wave { case square, triangle, sine, noise }

    /// Notes as (MIDI-ish) frequencies; every effect stays under a second.
    static func samples(for effect: Effect) -> [Float] {
        func n(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
        let notes: [Note]
        switch effect {
        case .bookDone:
            notes = [Note(frequency: n(72), duration: 0.09), Note(frequency: n(76), duration: 0.09),
                     Note(frequency: n(79), duration: 0.09), Note(frequency: n(84), duration: 0.32, wave: .triangle)]
        case .owlHoot:
            notes = [Note(frequency: n(64), duration: 0.16, wave: .sine, vibrato: 6),
                     Note(frequency: 0, duration: 0.06),
                     Note(frequency: n(62), duration: 0.38, wave: .sine, glideTo: n(60), vibrato: 5)]
        case .bark:
            notes = [Note(frequency: n(64), duration: 0.07, wave: .noise),
                     Note(frequency: n(70), duration: 0.12, wave: .square, glideTo: n(58))]
        case .achievement:
            notes = [Note(frequency: n(79), duration: 0.07), Note(frequency: n(83), duration: 0.07),
                     Note(frequency: n(86), duration: 0.07), Note(frequency: n(91), duration: 0.28, wave: .triangle)]
        case .retroDing:
            notes = [Note(frequency: n(81), duration: 0.12, wave: .sine), Note(frequency: n(76), duration: 0.32, wave: .sine)]
        case .powerUp:
            notes = (0..<10).map { Note(frequency: n(60 + Double($0) * 2.4), duration: 0.045) }
                + [Note(frequency: n(84), duration: 0.25, wave: .triangle)]
        case .pet:
            notes = [Note(frequency: n(88), duration: 0.06, wave: .triangle), Note(frequency: n(93), duration: 0.09, wave: .triangle)]
        }
        return render(notes)
    }

    private static func render(_ notes: [Note], sampleRate: Double = 44_100) -> [Float] {
        var out: [Float] = []
        var phase = 0.0
        var seed: UInt32 = 0x2545F491
        for note in notes {
            let count = Int(note.duration * sampleRate)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let progress = Double(i) / Double(max(count, 1))
                guard note.frequency > 0 else { out.append(0); continue }
                var frequency = note.frequency
                if let target = note.glideTo { frequency += (target - note.frequency) * progress }
                if note.vibrato > 0 { frequency *= 1 + 0.012 * sin(2 * .pi * note.vibrato * t) }
                phase += frequency / sampleRate
                let cycle = phase - floor(phase)
                var value: Double
                switch note.wave {
                case .square: value = cycle < 0.5 ? 0.6 : -0.6
                case .triangle: value = 4 * abs(cycle - 0.5) - 1
                case .sine: value = sin(2 * .pi * cycle)
                case .noise:
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                    value = Double(seed) / Double(UInt32.max) * 2 - 1
                }
                // Short attack, smooth release: no clicks.
                let attack = min(1, t / 0.006)
                let release = min(1, (note.duration - t) / 0.03)
                out.append(Float(value * attack * max(0, release) * 0.5))
            }
        }
        return out
    }
}

extension ProcessInfo {
    var isRunningTests: Bool { environment["XCTestConfigurationFilePath"] != nil }
}
