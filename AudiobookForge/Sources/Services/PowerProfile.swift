import Foundation
import SwiftUI
import IOKit.ps
import Observation

/// Energy profile (v3.2): one choice for the power adapter, one for the
/// battery. It changes real work, not just a label — how many chapters are
/// rendered at once, how the speech-engine processes are scheduled (fast
/// cores vs. efficiency cores), how much GPU memory MLX may keep cached,
/// how many LLM requests run in parallel, and whether scenes animate.
enum PowerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case maximum
    case balanced
    case saver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .maximum: return L("Maximal")
        case .balanced: return L("Ausgewogen")
        case .saver: return L("Stromsparend")
        }
    }

    var summary: String {
        switch self {
        case .maximum: return L("Mindestens 2 Worker, schnelle Kerne, großer MLX-Cache, volle Animationen")
        case .balanced: return L("Höchstens 2 Worker, normale Priorität, Animationen an")
        case .saver: return L("1 Worker auf Effizienzkernen, kleiner Speicher, ruhende Szenen")
        }
    }

    /// Parallel chapter workers, given the user's setting (1…4).
    func ttsWorkers(userSetting: Int) -> Int {
        switch self {
        // Measured 2026-10-19 (Kokoro, 12k chars): 1 worker 448 chars/s,
        // 2 → 617 (+38 %), 3 → 618 (GPU saturated, +4 GB RAM). So the
        // maximum profile runs at least 2; more only if set explicitly.
        case .maximum: return max(2, min(userSetting, 4))
        case .balanced: return max(1, min(userSetting, 2))
        case .saver: return 1
        }
    }

    /// Parallel LLM requests, given the configured value.
    func llmRequests(configured: Int) -> Int {
        switch self {
        case .maximum: return max(1, configured)
        case .balanced: return max(1, min(configured, 2))
        case .saver: return 1
        }
    }

    /// MLX buffer cache cap per bridge process (MB), passed as
    /// ABF_MLX_CACHE_MB (bridges default to 256).
    var mlxCacheMB: Int {
        switch self {
        case .maximum: return 512
        case .balanced: return 256
        case .saver: return 96
        }
    }

    /// Scheduling of the speech-engine processes. `.background` keeps them
    /// on the efficiency cores on Apple silicon.
    var processQoS: QualityOfService {
        switch self {
        case .maximum: return .userInitiated
        case .balanced: return .utility
        case .saver: return .background
        }
    }

    /// Scenes, the shelf cat and the moving background animate.
    var animates: Bool { self != .saver }
}

/// Watches the power source (adapter/battery) and macOS Low Power Mode.
@MainActor @Observable
final class PowerMonitor {
    static let shared = PowerMonitor()

    private(set) var onAdapter = true
    private(set) var systemLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    private init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PowerMonitor.shared.refresh() }
        }
    }

    func refresh() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        // Desktops report no battery at all: treat as adapter.
        onAdapter = type == nil || type == kIOPSACPowerValue
        systemLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// The mode in force now. macOS Low Power Mode always wins.
    func mode(for settings: AppSettings) -> PowerMode {
        let mode = systemLowPower ? .saver : (onAdapter ? settings.powerModeOnAdapter : settings.powerModeOnBattery)
        PowerProfile.current = mode
        return mode
    }
}

/// Thread-safe snapshot of the mode in force, for work off the main actor
/// (engine processes, pipeline).
enum PowerProfile {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: PowerMode = .balanced

    static var current: PowerMode {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension Process {
    /// Applies the energy profile to a speech-engine process: scheduling
    /// class and the MLX cache cap. Call right before `run()`.
    func applyPowerProfile() {
        let mode = PowerProfile.current
        qualityOfService = mode.processQoS
        var env = environment ?? ProcessInfo.processInfo.environment
        env["ABF_MLX_CACHE_MB"] = String(mode.mlxCacheMB)
        environment = env
    }
}

extension EnvironmentValues {
    /// False in the power-saving profile: scenes, the shelf cat and the
    /// moving background stand still.
    @Entry var energyAnimates: Bool = true
}
