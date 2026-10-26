import Foundation

/// Expression controls (v4.2): one "calm ↔ lively" slider per engine whose
/// default sits in the middle. The ranges stay inside what the runtimes
/// handle cleanly; above ~0.7 temperature, slips and odd stress appear.
enum ExpressionDefaults {
    /// Phonon and Pocket TTS sampling temperature (both runtimes' default).
    static let temperature = 0.3
    static let temperatureRange: ClosedRange<Double> = 0.1...0.7
    /// Piper noise_scale (prosody); noise_w (rhythm) follows proportionally.
    static let piperNoiseScale = 0.667
    static let piperNoiseW = 0.8
    static let piperNoiseScaleRange: ClosedRange<Double> = 0.3...1.0

    /// Piper's rhythm noise for a prosody value, keeping the model's ratio.
    static func piperNoiseW(forNoiseScale scale: Double) -> Double {
        (piperNoiseW * scale / piperNoiseScale * 1000).rounded() / 1000
    }

    /// Slider position 0…1 → value, piecewise linear so `standard` sits at 0.5.
    static func value(atPosition position: Double, range: ClosedRange<Double>, standard: Double) -> Double {
        let p = min(1, max(0, position))
        return p <= 0.5
            ? range.lowerBound + (standard - range.lowerBound) * (p / 0.5)
            : standard + (range.upperBound - standard) * ((p - 0.5) / 0.5)
    }

    /// Inverse of `value(atPosition:)`.
    static func position(of value: Double, range: ClosedRange<Double>, standard: Double) -> Double {
        let v = min(range.upperBound, max(range.lowerBound, value))
        if v <= standard {
            return standard == range.lowerBound ? 0.5 : 0.5 * (v - range.lowerBound) / (standard - range.lowerBound)
        }
        return 0.5 + 0.5 * (v - standard) / (range.upperBound - standard)
    }

    static func isStandard(_ value: Double, _ standard: Double) -> Bool { abs(value - standard) < 0.005 }
}
