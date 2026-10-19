import SwiftUI

// MARK: - Accent colors (plan 9.1, Vorlage: NativeTongue-Screenshot)

/// The app's accent palette. Each accent carries the two colors of its
/// gradient (the background mesh and highlights derive from them) plus a
/// plain tint color for controls. `system` follows the macOS accent.
enum AppAccent: String, Codable, CaseIterable, Sendable, Identifiable, Equatable {
    case system
    case violet
    case indigo
    case ocean
    case teal
    case coral
    case rose
    case amber
    case graphite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("System")
        case .violet: return L("Violett")
        case .indigo: return L("Indigo")
        case .ocean: return L("Ozean")
        case .teal: return L("Petrol")
        case .coral: return L("Koralle")
        case .rose: return L("Rose")
        case .amber: return L("Bernstein")
        case .graphite: return L("Graphit")
        }
    }

    /// Control tint. `system` resolves at use time (the computed property
    /// can't, so callers special-case it — see `Theme.tint`).
    var baseColor: Color {
        switch self {
        case .system: return .accentColor
        case .violet: return Color(red: 0.55, green: 0.35, blue: 0.97)
        case .indigo: return Color(red: 0.35, green: 0.36, blue: 0.95)
        case .ocean: return Color(red: 0.15, green: 0.50, blue: 0.95)
        case .teal: return Color(red: 0.10, green: 0.62, blue: 0.72)
        case .coral: return Color(red: 0.98, green: 0.45, blue: 0.34)
        case .rose: return Color(red: 0.94, green: 0.36, blue: 0.54)
        case .amber: return Color(red: 0.95, green: 0.66, blue: 0.22)
        case .graphite: return Color(red: 0.38, green: 0.40, blue: 0.45)
        }
    }

    /// Second gradient color — slightly shifted from the base for depth.
    var gradientPartner: Color {
        switch self {
        case .system: return Color.blue.opacity(0.8)
        case .violet: return Color(red: 0.32, green: 0.55, blue: 0.99)
        case .indigo: return Color(red: 0.55, green: 0.42, blue: 0.98)
        case .ocean: return Color(red: 0.30, green: 0.75, blue: 0.95)
        case .teal: return Color(red: 0.35, green: 0.85, blue: 0.65)
        case .coral: return Color(red: 1.00, green: 0.65, blue: 0.42)
        case .rose: return Color(red: 1.00, green: 0.55, blue: 0.45)
        case .amber: return Color(red: 1.00, green: 0.80, blue: 0.40)
        case .graphite: return Color(red: 0.55, green: 0.58, blue: 0.65)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [baseColor, gradientPartner],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Swatch preview (used by the settings picker).
    var swatchGradient: LinearGradient { gradient }

    /// Raw sRGB components (0...1) of the base color — the unit-testable
    /// source for WCAG contrast math (no Color→NSColor round trip needed).
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .system: return (0.20, 0.46, 1.00) // macOS-Standardakzent (blau)
        case .violet: return (0.55, 0.35, 0.97)
        case .indigo: return (0.35, 0.36, 0.95)
        case .ocean: return (0.15, 0.50, 0.95)
        case .teal: return (0.10, 0.62, 0.72)
        case .coral: return (0.98, 0.45, 0.34)
        case .rose: return (0.94, 0.36, 0.54)
        case .amber: return (0.95, 0.66, 0.22)
        case .graphite: return (0.38, 0.40, 0.45)
        }
    }
}

/// Pure WCAG 2.x contrast math (plan 9.2: the appearance tests compute
/// ratios from raw color values, no rendering involved).
enum ContrastMath {
    /// WCAG relative luminance of an sRGB color given 0...1 components.
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// WCAG contrast ratio between two luminances (1...21).
    static func ratio(_ l1: Double, _ l2: Double) -> Double {
        let lighter = max(l1, l2), darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func contrast(_ a: (red: Double, green: Double, blue: Double),
                         _ b: (red: Double, green: Double, blue: Double)) -> Double {
        ratio(luminance(red: a.red, green: a.green, blue: a.blue),
              luminance(red: b.red, green: b.green, blue: b.blue))
    }

    static let white = (red: 1.0, green: 1.0, blue: 1.0)
    static let black = (red: 0.0, green: 0.0, blue: 0.0)
}

extension AppAccent {
    var baseLuminance: Double {
        ContrastMath.luminance(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Prominent buttons fill with the accent: bright accents (amber,
    /// coral) get BLACK text, darker ones white — the pair that passes
    /// WCAG ≥ 4.5:1 (unit-tested in AppearanceSettingsTests).
    var prominentTextIsLight: Bool {
        let contrastWhite = ContrastMath.ratio(1.0, baseLuminance)
        let contrastBlack = ContrastMath.ratio(baseLuminance, ContrastMath.luminance(red: 0, green: 0, blue: 0))
        return contrastWhite >= contrastBlack
    }
}

// MARK: - Theme (plan 9.1)

/// Central design tokens for the "Flow" design language. Radii and spacing
/// come from the NativeTongue template (docs/DESIGN_VORLAGE.md); typography
/// scales with the user's text-size step (plan 9.2).
enum Theme {
    enum Radius {
        static let panel: CGFloat = 28
        static let card: CGFloat = 22
        /// Settings rows / list pills (template: tall rounded pills).
        static let row: CGFloat = 20
        static let pill: CGFloat = 16
        static let segment: CGFloat = 10
    }

    enum Spacing {
        static let tight: CGFloat = 6
        static let regular: CGFloat = 12
        static let loose: CGFloat = 20
        static let section: CGFloat = 28
    }

    enum Shadow {
        static let soft = Color.black.opacity(0.10)
        static let medium = Color.black.opacity(0.16)
    }

    /// Text sizes across the app, multiplied by the user's scale factor.
    /// The factor is monotonic in the step (unit-tested in
    /// AppearanceSettingsTests) so L is always ≥ M etc.
    static func textScale(for step: TextSizeStep) -> Double {
        switch step {
        case .system: return 1.0
        case .xs: return 0.85
        case .s: return 0.92
        case .m: return 1.0
        case .l: return 1.12
        case .xl: return 1.25
        case .xxl: return 1.4
        }
    }

    /// Maps the user's TextSizeStep to SwiftUI's DynamicTypeSize for system-wide font scaling.
    static func dynamicTypeSize(for step: TextSizeStep) -> DynamicTypeSize {
        switch step {
        case .system: return .medium
        case .xs: return .xSmall
        case .s: return .small
        case .m: return .medium
        case .l: return .large
        case .xl: return .xLarge
        case .xxl: return .xxxLarge
        }
    }

    enum Typography {
        /// Scaled font for a design-system role. `size` is the M-step size.
        static func font(_ role: Role, scaledBy factor: Double) -> Font {
            switch role {
            case .title: return .system(size: 22 * factor, weight: .bold)
            case .title2: return .system(size: 19 * factor, weight: .bold)
            case .title3: return .system(size: 16 * factor, weight: .bold)
            case .headline: return .system(size: 14 * factor, weight: .semibold)
            case .body: return .system(size: 13 * factor)
            case .callout: return .system(size: 12 * factor)
            case .caption: return .system(size: 11 * factor)
            case .caption2: return .system(size: 10 * factor)
            }
        }

        enum Role { case title, title2, title3, headline, body, callout, caption, caption2 }
    }

    /// The effective control tint for the selected accent.
    static func tint(for accent: AppAccent) -> Color {
        accent == .system ? .accentColor : accent.baseColor
    }
}

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var appTextScale: Double {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

/// Text size steps (plan 9.2). `system` resolves to M unless the user
/// picks an explicit step; the steps are strictly monotonic.
enum TextSizeStep: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case xs
    case s
    case m
    case l
    case xl
    case xxl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("System")
        case .xs: return L("XS")
        case .s: return "S"
        case .m: return "M"
        case .l: return "L"
        case .xl: return L("XL")
        case .xxl: return L("XXL")
        }
    }
}

/// Appearance mode (plan 9.2).
enum AppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Hell")
        case .dark: return L("Dunkel")
        }
    }
}

/// Sidebar grouping mode (plan 9.5).
enum SidebarGrouping: String, Codable, CaseIterable, Sendable, Identifiable {
    case topic
    case documentType
    case author
    case status
    case none

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .topic: return L("Thema")
        case .documentType: return L("Dokumenttyp")
        case .author: return L("Autor")
        case .status: return L("Status")
        case .none: return L("Keine")
        }
    }
}

/// Motion preference (plan 9.2) — the default follows the system setting.
enum MotionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case reduced
    case off

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return L("Automatisch (System)")
        case .reduced: return L("Reduziert")
        case .off: return L("Aus")
        }
    }
}

// MARK: - Accent + surface environment (v3.1)

extension EnvironmentValues {
    /// The user's accent, injected once at the root. Components read this
    /// instead of hard-coding a color, so every surface follows the choice.
    @Entry var flowAccent: AppAccent = .violet
    /// Material level of content surfaces (cards, panels).
    @Entry var surfaceLevel: SurfaceLevel = .frosted
}

/// Template "Glass" setting: Clear / Frosted / Solid. Stored as the legacy
/// 0…100 `glassIntensity` so old settings files keep working.
enum SurfaceLevel: String, CaseIterable, Identifiable, Sendable {
    case clear
    case frosted
    case solid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clear: return L("Klar")
        case .frosted: return L("Milchig")
        case .solid: return L("Deckend")
        }
    }

    var explanation: String {
        switch self {
        case .clear: return L("Durchscheinende Flächen, der Farbverlauf leuchtet stark durch.")
        case .frosted: return L("Mattiertes Glas — Standard, ruhig und gut lesbar.")
        case .solid: return L("Deckende Flächen ohne Transparenz.")
        }
    }

    init(intensity: Double) {
        switch intensity {
        case ..<45: self = .clear
        case ..<90: self = .frosted
        default: self = .solid
        }
    }

    var intensity: Double {
        switch self {
        case .clear: return 30
        case .frosted: return 80
        case .solid: return 100
        }
    }
}

extension AppAccent {
    /// Resolved control color (system accent for `.system`).
    var color: Color { Theme.tint(for: self) }

    /// How much a prominent fill is deepened (mixed with black) so WHITE
    /// text reaches WCAG 4.5:1 on it — the template shows white on the
    /// accent. Light accents (amber) would turn muddy; they keep their
    /// color and get black text instead.
    var prominentDeepening: Double? {
        var amount = 0.0
        while amount <= 0.3 + 1e-9 {
            let r = rgb.red * (1 - amount), g = rgb.green * (1 - amount), b = rgb.blue * (1 - amount)
            let contrast = ContrastMath.ratio(1.0, ContrastMath.luminance(red: r, green: g, blue: b))
            if contrast >= 4.5 { return amount }
            amount += 0.03
        }
        return nil
    }

    /// Text/icon color on a prominent accent fill.
    var onAccent: Color { prominentDeepening == nil ? .black : .white }

    /// Accent gradient for prominent fills (`.system` uses the macOS accent).
    var fill: LinearGradient {
        if self == .system {
            return LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let deepen = prominentDeepening ?? 0
        return LinearGradient(colors: [baseColor.mix(with: .black, by: deepen),
                                       gradientPartner.mix(with: .black, by: deepen + 0.05)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Theme {
    enum Motion {
        /// The app's standard "flow" spring: soft, no overshoot jitter.
        static let flow = Animation.spring(response: 0.38, dampingFraction: 0.86)
        static let quick = Animation.easeOut(duration: 0.16)
    }
}

extension View {
    /// Scaled design-system font (follows the user's text-size step).
    func flowFont(_ role: Theme.Typography.Role, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(FlowFontModifier(role: role, weight: weight, design: design))
    }
}

private struct FlowFontModifier: ViewModifier {
    let role: Theme.Typography.Role
    let weight: Font.Weight?
    let design: Font.Design
    @Environment(\.appTextScale) private var scale

    func body(content: Content) -> some View {
        let base: (CGFloat, Font.Weight) = {
            switch role {
            case .title: return (26, .bold)
            case .title2: return (20, .bold)
            case .title3: return (16, .semibold)
            case .headline: return (13.5, .semibold)
            case .body: return (13, .regular)
            case .callout: return (12, .regular)
            case .caption: return (11, .regular)
            case .caption2: return (10, .medium)
            }
        }()
        content.font(.system(size: base.0 * scale, weight: weight ?? base.1, design: design))
    }
}
