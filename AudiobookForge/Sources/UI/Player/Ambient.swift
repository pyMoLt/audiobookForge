import SwiftUI
import AVFoundation
import AudioToolbox
import Observation

// MARK: - Ambient scenes (plan 9.6 / v3.1 — only in the app player, never
// in the exported audio)

/// The available ambient scenes. Raw values of the v3.0 scenes (`fire`,
/// `rain`, `water`) are unchanged so per-book choices survive the update.
enum AmbientSound: String, Codable, CaseIterable, Sendable, Identifiable, Equatable {
    case fire
    case rain
    case storm
    case ocean
    case water
    case forest
    case cyberpunk
    case train

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fire: return L("Kaminfeuer")
        case .rain: return L("Regen")
        case .storm: return L("Gewitter")
        case .ocean: return L("Meer")
        case .water: return L("Bach")
        case .forest: return L("Dschungel")
        case .cyberpunk: return L("Neonstadt")
        case .train: return L("Zugfahrt")
        }
    }

    var systemImage: String {
        switch self {
        case .fire: return "flame.fill"
        case .rain: return "cloud.rain.fill"
        case .storm: return "cloud.bolt.rain.fill"
        case .ocean: return "water.waves"
        case .water: return "drop.fill"
        case .forest: return "leaf.fill"
        case .cyberpunk: return "building.2.fill"
        case .train: return "tram.fill"
        }
    }

    /// Bed loop resource (Resources/Ambient/<name>.m4a).
    var resourceName: String { rawValue }

    /// Prefix of the one-shot event files (Resources/Ambient/<prefix>_N.m4a).
    var eventResourcePrefix: String { "\(rawValue)_evt" }

    /// Window mood while the scene runs (tints the flow background).
    var mood: BackgroundMood {
        switch self {
        case .fire:
            return BackgroundMood(primary: Color(red: 1.0, green: 0.46, blue: 0.16),
                                  secondary: Color(red: 0.98, green: 0.72, blue: 0.36),
                                  deep: Color(red: 0.62, green: 0.16, blue: 0.08), strength: 0.85)
        case .rain:
            return BackgroundMood(primary: Color(red: 0.36, green: 0.48, blue: 0.70),
                                  secondary: Color(red: 0.62, green: 0.74, blue: 0.86),
                                  deep: Color(red: 0.20, green: 0.26, blue: 0.40), strength: 0.8)
        case .storm:
            return BackgroundMood(primary: Color(red: 0.30, green: 0.30, blue: 0.55),
                                  secondary: Color(red: 0.50, green: 0.56, blue: 0.76),
                                  deep: Color(red: 0.12, green: 0.12, blue: 0.26), strength: 0.9)
        case .ocean:
            return BackgroundMood(primary: Color(red: 0.10, green: 0.50, blue: 0.75),
                                  secondary: Color(red: 0.45, green: 0.82, blue: 0.88),
                                  deep: Color(red: 0.04, green: 0.22, blue: 0.42), strength: 0.8)
        case .water:
            return BackgroundMood(primary: Color(red: 0.16, green: 0.62, blue: 0.62),
                                  secondary: Color(red: 0.62, green: 0.88, blue: 0.80),
                                  deep: Color(red: 0.06, green: 0.32, blue: 0.34), strength: 0.75)
        case .forest:
            return BackgroundMood(primary: Color(red: 0.18, green: 0.48, blue: 0.30),
                                  secondary: Color(red: 0.56, green: 0.78, blue: 0.44),
                                  deep: Color(red: 0.05, green: 0.20, blue: 0.14), strength: 0.85)
        case .cyberpunk:
            return BackgroundMood(primary: Color(red: 0.62, green: 0.28, blue: 0.86),
                                  secondary: Color(red: 0.30, green: 0.78, blue: 0.92),
                                  deep: Color(red: 0.12, green: 0.08, blue: 0.26), strength: 0.85)
        case .train:
            return BackgroundMood(primary: Color(red: 0.56, green: 0.38, blue: 0.62),
                                  secondary: Color(red: 0.96, green: 0.62, blue: 0.42),
                                  deep: Color(red: 0.16, green: 0.12, blue: 0.22), strength: 0.8)
        }
    }

    /// One-shot event layers that break up the loop (crackles, logs,
    /// thunder, drips, birds …). Rates are per minute at full intensity.
    var eventRecipe: AmbientEventRecipe {
        switch self {
        case .fire:
            return AmbientEventRecipe(perMinute: 26, gain: 0.35...0.9, pan: -0.7...0.7, rate: 0.85...1.15, minGap: 0.4)
        case .rain:
            return AmbientEventRecipe(perMinute: 8, gain: 0.25...0.6, pan: -0.9...0.9, rate: 0.9...1.1, minGap: 2)
        case .storm:
            return AmbientEventRecipe(perMinute: 2.2, gain: 0.55...1.0, pan: -0.6...0.6, rate: 0.85...1.05, minGap: 12, flashesBeforeEvent: true)
        case .ocean:
            return AmbientEventRecipe(perMinute: 3, gain: 0.3...0.7, pan: -0.8...0.8, rate: 0.9...1.1, minGap: 6)
        case .water:
            return AmbientEventRecipe(perMinute: 10, gain: 0.25...0.6, pan: -0.8...0.8, rate: 0.9...1.15, minGap: 1.5)
        case .forest:
            return AmbientEventRecipe(perMinute: 9, gain: 0.2...0.6, pan: -0.95...0.95, rate: 0.92...1.08, minGap: 2.5)
        case .cyberpunk:
            // Passing cars, distant sirens, a door, voices.
            return AmbientEventRecipe(perMinute: 5, gain: 0.25...0.65, pan: -0.9...0.9, rate: 0.92...1.08, minGap: 5)
        case .train:
            // Rail joints, a horn far ahead, the carriage creaking.
            return AmbientEventRecipe(perMinute: 4, gain: 0.3...0.7, pan: -0.5...0.5, rate: 0.95...1.05, minGap: 6)
        }
    }
}

// MARK: - Loop planning (pure, testable)

/// Playback plan for one ambient bed loop: linear volume ramps and the
/// crossfade bound. The unit tests assert ramp linearity, the ≤ loop/4
/// crossfade bound and the state machine (plan 9.6).
struct AmbientLoopPlanner: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case playing
        case paused
    }

    var state: State = .idle
    var loopSeconds: Double
    var crossfadeSeconds: Double

    init(loopSeconds: Double, crossfadeSeconds: Double? = nil) {
        self.loopSeconds = loopSeconds
        let requested = crossfadeSeconds ?? 1.5
        self.crossfadeSeconds = min(requested, loopSeconds / 4)
    }

    static func fadeGain(at fraction: Double, rising: Bool) -> Double {
        let clamped = min(max(fraction, 0), 1)
        return rising ? clamped : 1 - clamped
    }

    mutating func start() -> Bool {
        guard state != .playing else { return false }
        state = .playing
        return true
    }
    mutating func pause() -> Bool {
        guard state == .playing else { return false }
        state = .paused
        return true
    }
    mutating func resume() -> Bool {
        guard state == .paused else { return false }
        state = .playing
        return true
    }
    mutating func stop() -> Bool {
        guard state != .idle else { return false }
        state = .idle
        return true
    }
}

// MARK: - Event planning (pure, testable)

/// How a scene's one-shot layer behaves.
struct AmbientEventRecipe: Equatable, Sendable {
    /// Mean events per minute at intensity 1.
    var perMinute: Double
    var gain: ClosedRange<Double>
    var pan: ClosedRange<Double>
    /// Playback-rate (varispeed) variation — pitch + speed together.
    var rate: ClosedRange<Double>
    /// Minimum seconds between two events.
    var minGap: Double
    /// Storm: a lightning flash precedes the thunder by 0.4–2.5 s.
    var flashesBeforeEvent: Bool = false
}

/// One scheduled one-shot.
struct AmbientEvent: Equatable, Sendable {
    var delay: Double
    var variant: Int
    var gain: Double
    var pan: Double
    var rate: Double
    /// Seconds between the visual flash and the sound (storm only).
    var flashLead: Double?
}

/// Deterministic random event generator: exponential inter-arrival times
/// (Poisson process) so events never fall into an audible rhythm, with
/// gain/pan/rate jitter per event. Seedable for tests.
struct AmbientEventPlanner: Sendable {
    let recipe: AmbientEventRecipe
    let variants: Int
    private var rng: SplitMix64
    private var lastVariant: Int = -1

    init(recipe: AmbientEventRecipe, variants: Int, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.recipe = recipe
        self.variants = max(1, variants)
        self.rng = SplitMix64(seed: seed)
    }

    /// Next event for the given intensity (0…1). Lower intensity → fewer,
    /// quieter events; at 0 the planner still returns sparse events.
    mutating func next(intensity: Double) -> AmbientEvent {
        let level = min(max(intensity, 0), 1)
        let perMinute = max(0.2, recipe.perMinute * (0.25 + 0.75 * level))
        let mean = 60 / perMinute
        let u = max(1e-6, rng.nextUnit())
        let delay = max(recipe.minGap, -log(u) * mean)

        var variant = Int(rng.nextUnit() * Double(variants)) % variants
        if variants > 1, variant == lastVariant { variant = (variant + 1) % variants }
        lastVariant = variant

        let gainScale = 0.55 + 0.45 * level
        let gain = lerp(recipe.gain, rng.nextUnit()) * gainScale
        let pan = lerp(recipe.pan, rng.nextUnit())
        let rate = lerp(recipe.rate, rng.nextUnit())
        let flashLead = recipe.flashesBeforeEvent ? 0.4 + rng.nextUnit() * 2.1 : nil
        return AmbientEvent(delay: delay, variant: variant, gain: gain, pan: pan, rate: rate, flashLead: flashLead)
    }

    private func lerp(_ range: ClosedRange<Double>, _ t: Double) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
}

/// Small deterministic PRNG (tests need reproducible sequences).
struct SplitMix64: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

// MARK: - Controller (UI state)

/// The ambience as the UI sees it: scene, volume, intensity, the sleep
/// burn-down and the storm flash. Owns the audio engine. App-wide (via
/// `PlaybackSession`) so the scene survives navigation.
@MainActor
@Observable
final class AmbientController {
    private(set) var scene: AmbientSound?
    /// 0…1 linear gain of the ambience relative to the book.
    private(set) var volume: Double = 0.35
    /// 0…1 — flame height, rain density, event rate.
    private(set) var intensity: Double = {
        let stored = UserDefaults.standard.object(forKey: "ambient.intensity") as? Double
        return stored ?? 0.6
    }()
    /// True while sound is running (scene set and book playing / preview).
    private(set) var isAudible = false
    /// Last lightning flash (the storm visual reacts to changes).
    private(set) var lastFlash: Date?
    /// Sleep-timer end: the scene burns down over the last 10 minutes.
    private(set) var burnDownEnd: Date?

    @ObservationIgnored private let engine = AmbientAudioEngine()
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    var mood: BackgroundMood? { scene?.mood }

    /// Intensity including the sleep-timer burn-down (visual + audio).
    func effectiveIntensity(at date: Date = Date()) -> Double {
        guard let burnDownEnd else { return intensity }
        let remaining = burnDownEnd.timeIntervalSince(date)
        let window = 600.0
        guard remaining < window else { return intensity }
        return intensity * max(0.08, remaining / window)
    }

    /// Choose a scene (nil = off). Starts the sound right away so the
    /// choice can be heard; afterwards it follows the book's play state.
    func select(_ newScene: AmbientSound?, bookIsPlaying: Bool) {
        guard newScene != scene else { return }
        scene = newScene
        engine.stop()
        stopEvents()
        isAudible = false
        guard let newScene else { return }
        if engine.start(scene: newScene, volume: volume, intensity: effectiveIntensity()) {
            isAudible = true
            startEvents(for: newScene)
            if !bookIsPlaying {
                // Short preview, then wait for the book.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard let self, self.scene == newScene, !self.bookPlaying else { return }
                    self.engine.pause()
                    self.stopEvents()
                    self.isAudible = false
                }
            }
        }
    }

    @ObservationIgnored private var bookPlaying = false

    func setVolume(_ newValue: Double) {
        volume = min(max(newValue, 0), 1)
        engine.setVolume(volume)
    }

    func setIntensity(_ newValue: Double) {
        intensity = min(max(newValue, 0), 1)
        UserDefaults.standard.set(intensity, forKey: "ambient.intensity")
        engine.setIntensity(effectiveIntensity())
    }

    func followPlayback(isPlaying: Bool) {
        bookPlaying = isPlaying
        guard let scene else { return }
        if isPlaying {
            if engine.resume() || engine.start(scene: scene, volume: volume, intensity: effectiveIntensity()) {
                isAudible = true
                if eventTask == nil { startEvents(for: scene) }
            }
        } else {
            engine.pause()
            stopEvents()
            isAudible = false
        }
    }

    func restore(for book: BookProject) {
        if let percent = book.ambientVolumePercent {
            volume = min(max(Double(percent) / 100, 0), 1)
        }
        let restored = book.ambientSound.flatMap(AmbientSound.init(rawValue:))
        if restored != scene {
            scene = nil
            engine.stop()
            stopEvents()
            isAudible = false
            if let restored {
                scene = restored
                if bookPlaying { followPlayback(isPlaying: true) }
            }
        }
    }

    func stop() {
        scene = nil
        engine.stop()
        stopEvents()
        isAudible = false
    }

    func setBurnDown(_ end: Date?) {
        burnDownEnd = end
        engine.setIntensity(effectiveIntensity())
    }

    // MARK: Events

    private func startEvents(for scene: AmbientSound) {
        stopEvents()
        let variants = engine.eventVariantCount
        guard variants > 0 else { return }
        var planner = AmbientEventPlanner(recipe: scene.eventRecipe, variants: variants)
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = self.effectiveIntensity()
                let event = planner.next(intensity: level)
                self.engine.setIntensity(level)
                try? await Task.sleep(for: .seconds(event.delay))
                guard !Task.isCancelled, self.scene == scene, self.isAudible else { return }
                if let lead = event.flashLead {
                    self.lastFlash = Date()
                    try? await Task.sleep(for: .seconds(lead))
                    guard !Task.isCancelled else { return }
                }
                self.engine.playEvent(event)
            }
        }
    }

    private func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
    }
}

// MARK: - Audio engine

/// Ambient sound on its own `AVAudioEngine`: a seamless bed loop plus a
/// pool of one-shot voices (pan + varispeed per event). Never touches the
/// exported M4B/chapter audio.
@MainActor
final class AmbientAudioEngine {
    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private var bedNode: AVAudioPlayerNode?
    private var bedBuffer: AVAudioPCMBuffer?
    private var eventBuffers: [AVAudioPCMBuffer] = []
    /// Pre-rendered pitch/speed variants per event: [event][rate] — no
    /// realtime resampler (six live varispeed units cost ~20 % CPU).
    private var eventVariants: [[AVAudioPCMBuffer]] = []
    static let variantRates: [Double] = [0.88, 1.0, 1.12]
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var planner = AmbientLoopPlanner(loopSeconds: 90)
    private var volume: Double = 0.35
    private var intensity: Double = 0.6
    private var rampTask: Task<Void, Never>?
    private var isSetUp = false

    static let voiceCount = 4

    var eventVariantCount: Int { eventBuffers.count }

    /// Bed level for a given intensity: quiet scenes still keep a floor.
    static func bedGain(intensity: Double) -> Double {
        0.55 + 0.45 * min(max(intensity, 0), 1)
    }

    private func setUpGraph() {
        guard !isSetUp else { return }
        engine.attach(bus)
        engine.connect(bus, to: engine.mainMixerNode, format: nil)
        bus.outputVolume = 0
        Self.useLargeIOBuffer(engine)
        isSetUp = true
    }

    /// Ambience needs no low latency: render in large blocks (~85 ms) so the
    /// audio thread wakes up a few dozen times per second instead of
    /// hundreds — the main CPU cost of the engine (v3.2 measurement).
    static let ioBufferFrames: UInt32 = 4096

    private static func useLargeIOBuffer(_ engine: AVAudioEngine) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames = ioBufferFrames
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
    }

    /// Loads the scene's assets and fades in. False when assets are missing.
    @discardableResult
    func start(scene: AmbientSound, volume: Double, intensity: Double) -> Bool {
        stopNodes()
        setUpGraph()
        guard let rawBed = Self.loadBuffer(named: scene.resourceName) else { return false }
        // Convert once to the output device's rate — no realtime SRC.
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let bed = Self.matching(rawBed, sampleRate: outputRate)
        self.volume = volume
        self.intensity = intensity
        bedBuffer = bed
        eventBuffers = Self.loadEventBuffers(prefix: scene.eventResourcePrefix).map { Self.matching($0, sampleRate: outputRate) }
        planner = AmbientLoopPlanner(loopSeconds: Double(bed.frameLength) / bed.format.sampleRate)

        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: bus, format: bed.format)
        bedNode = node

        eventVariants = eventBuffers.map { buffer in
            Self.variantRates.map { rate in rate == 1 ? buffer : (Self.resampled(buffer, rate: rate) ?? buffer) }
        }
        if let format = eventBuffers.first?.format {
            for _ in 0..<Self.voiceCount {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: bus, format: format)
                voices.append(player)
            }
        }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return false
        }
        _ = planner.start()
        node.scheduleBuffer(bed, at: nil, options: .loops, completionHandler: nil)
        node.volume = Float(Self.bedGain(intensity: intensity))
        node.play()
        ramp(to: volume, duration: 2.0)
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard planner.state == .paused, bedNode != nil else { return false }
        _ = planner.resume()
        if !engine.isRunning { try? engine.start() }
        bedNode?.play()
        ramp(to: volume, duration: 1.5)
        return true
    }

    func pause() {
        guard planner.state == .playing else { return }
        _ = planner.pause()
        ramp(to: 0, duration: 1.5) { [weak self] in
            guard let self, self.planner.state == .paused else { return }
            self.bedNode?.pause()
            self.voices.forEach { $0.stop() }
            self.engine.pause()
        }
    }

    func stop() {
        guard planner.state != .idle else { return }
        _ = planner.stop()
        ramp(to: 0, duration: 1.2) { [weak self] in
            guard let self, self.planner.state == .idle else { return }
            self.stopNodes()
            self.engine.stop()
        }
    }

    func setVolume(_ newVolume: Double) {
        volume = newVolume
        if planner.state == .playing { ramp(to: newVolume, duration: 0.15) }
    }

    func setIntensity(_ newIntensity: Double) {
        intensity = newIntensity
        bedNode?.volume = Float(Self.bedGain(intensity: newIntensity))
    }

    func playEvent(_ event: AmbientEvent) {
        guard planner.state == .playing, !voices.isEmpty, eventVariants.indices.contains(event.variant) else { return }
        let voice = voices[nextVoice % voices.count]
        nextVoice += 1
        // Nearest pre-rendered rate variant.
        let rateIndex = Self.variantRates.enumerated().min { abs($0.element - event.rate) < abs($1.element - event.rate) }?.offset ?? 1
        voice.stop()
        voice.volume = Float(event.gain)
        voice.pan = Float(event.pan)
        voice.scheduleBuffer(eventVariants[event.variant][rateIndex], at: nil, options: [], completionHandler: nil)
        voice.play()
    }

    /// Offline pitch+speed change: resample to sampleRate/rate and play the
    /// result at the original rate.
    static func resampled(_ buffer: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer? {
        let source = buffer.format
        guard let target = AVAudioFormat(commonFormat: source.commonFormat, sampleRate: source.sampleRate / rate,
                                         channels: source.channelCount, interleaved: source.isInterleaved),
              let converted = convert(buffer, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: converted.frameLength) else { return nil }
        output.frameLength = converted.frameLength
        let channels = Int(source.channelCount)
        if let src = converted.floatChannelData, let dst = output.floatChannelData {
            for channel in 0..<(source.isInterleaved ? 1 : channels) {
                dst[channel].update(from: src[channel], count: Int(converted.frameLength) * (source.isInterleaved ? channels : 1))
            }
            return output
        }
        return nil
    }

    // MARK: Ramp (bus output volume, linear)

    private func ramp(to target: Double, duration: Double, completion: (@MainActor () -> Void)? = nil) {
        rampTask?.cancel()
        let start = Double(bus.outputVolume)
        let steps = max(1, Int(duration / 0.05))
        rampTask = Task { [weak self] in
            for tick in 1...steps {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                let fraction = Double(tick) / Double(steps)
                let gain = start + (target - start) * AmbientLoopPlanner.fadeGain(at: fraction, rising: true)
                self.bus.outputVolume = Float(gain)
            }
            guard !Task.isCancelled else { return }
            completion?()
        }
    }

    private func stopNodes() {
        rampTask?.cancel()
        bedNode?.stop()
        if let bedNode, engine.attachedNodes.contains(bedNode) { engine.detach(bedNode) }
        bedNode = nil
        for voice in voices {
            voice.stop()
            if engine.attachedNodes.contains(voice) { engine.detach(voice) }
        }
        eventVariants = []
        voices = []
        nextVoice = 0
    }

    // MARK: Assets

    /// The buffer in the given sample rate (same channels/layout).
    static func matching(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer {
        guard sampleRate > 0, abs(buffer.format.sampleRate - sampleRate) > 1,
              let format = AVAudioFormat(commonFormat: buffer.format.commonFormat, sampleRate: sampleRate,
                                         channels: buffer.format.channelCount, interleaved: buffer.format.isInterleaved),
              let converted = convert(buffer, to: format) else { return buffer }
        return converted
    }

    static func loadBuffer(named name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a") else { return nil }
        return loadBuffer(url: url)
    }

    static func loadBuffer(url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do {
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }

    /// All `<prefix>_N.m4a` one-shots, converted to one common format so
    /// the voice pool can play any of them.
    static func loadEventBuffers(prefix: String) -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        var index = 1
        while let url = Bundle.main.url(forResource: "\(prefix)_\(index)", withExtension: "m4a") {
            if let buffer = loadBuffer(url: url) {
                if let first = buffers.first, first.format != buffer.format {
                    if let converted = convert(buffer, to: first.format) { buffers.append(converted) }
                } else {
                    buffers.append(buffer)
                }
            }
            index += 1
        }
        return buffers
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
