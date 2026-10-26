import SwiftUI

/// Colors an ambient scene lends to the whole window (warm glow for the
/// fireplace, cool blue for rain …). Injected by the player while a scene
/// runs; `nil` means "use the accent".
struct BackgroundMood: Equatable, Sendable {
    var primary: Color
    var secondary: Color
    var deep: Color
    /// 0…1 — how strongly the mood replaces the accent colors.
    var strength: Double
}

extension EnvironmentValues {
    @Entry var backgroundMood: BackgroundMood? = nil
}

/// The app's colored background (template: soft multi-color field behind
/// every window). A 3×3 MeshGradient from the accent (or the active ambient
/// mood), drifting very slowly.
///
/// Behavior:
/// - Reduce Motion / motion setting → static.
/// - TimelineView only ticks for visible windows; 3 ticks/s + drawingGroup
///   keep idle CPU under the 3 % budget (docs/MESSUNGEN.md, 2026-10-18).
/// - "Subtle" halves the color strength, "Off" shows the plain window color.
struct FlowBackground: View {
    @Environment(\.energyAnimates) private var energyAnimates
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.backgroundMood) private var mood

    private var accent: AppAccent { settingsStore.settings.accent }
    private var motionAllowed: Bool {
        switch settingsStore.settings.motionMode {
        case .off, .reduced: return false
        case .system: return !systemReduceMotion
        }
    }

    var body: some View {
        Group {
            if settingsStore.settings.pixelMode {
                PixelBackdrop(color: accent.baseColor, dark: colorScheme == .dark)
            } else if settingsStore.settings.flowBackgroundEnabled || mood != nil {
                if motionAllowed && energyAnimates {
                    TimelineView(.animation(minimumInterval: 1.0 / 3.0)) { context in
                        mesh(phase: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    mesh(phase: 0)
                }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: mood)
        .ignoresSafeArea()
    }

    private func mesh(phase: TimeInterval) -> some View {
        let dark = colorScheme == .dark
        let a = accent.color
        let b = accent.gradientPartner
        // Template field: light cyan top-left, accent top-right, lavender
        // bottom — derived from the accent pair.
        var c1 = b
        var c2 = a
        var c3 = a.mix(with: .white, by: 0.45)
        if let mood {
            c1 = c1.mix(with: mood.secondary, by: mood.strength)
            c2 = c2.mix(with: mood.primary, by: mood.strength)
            c3 = c3.mix(with: mood.deep, by: mood.strength)
        }
        let strength = (settingsStore.settings.flowBackgroundEnabled ? 1.0 : 0.0)
        let base: Color = dark ? Color(white: 0.07) : Color(white: 0.985)
        let alpha: (Double) -> Double = { light in
            (dark ? light * 0.62 : light) * max(strength, mood?.strength ?? 0)
        }
        let t = motionAllowed ? phase : 0
        let dx = Float(sin(t * 0.11) * 0.08)
        let dy = Float(cos(t * 0.09) * 0.07)

        return ZStack {
            base
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + dx, 0], [1, 0],
                    [0, 0.5 + dy], [0.5 - dx, 0.5 + dy], [1, 0.5 - dy],
                    [0, 1], [0.5 + dx * 0.5, 1], [1, 1],
                ],
                colors: [
                    c1.opacity(alpha(0.42)), c2.opacity(alpha(0.22)), c2.opacity(alpha(0.46)),
                    c1.opacity(alpha(0.20)), base.opacity(0.0), c3.opacity(alpha(0.30)),
                    c3.opacity(alpha(0.40)), c2.opacity(alpha(0.18)), c1.opacity(alpha(0.36)),
                ],
                smoothsColors: true
            )
        }
        .drawingGroup()
    }
}

extension View {
    /// Large content panel (detail area, player panes) — same surface
    /// language as cards, with the panel radius.
    func flowPanel(cornerRadius: CGFloat = Theme.Radius.panel) -> some View {
        flowSurface(cornerRadius: cornerRadius)
    }
}

/// Pixel mode's background (v4.3): a flat tone with a coarse dither.
private struct PixelBackdrop: View {
    let color: Color
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark ? Color(white: 0.09) : Color(white: 0.93)))
            let cell: CGFloat = 8
            let tint = color.opacity(dark ? 0.16 : 0.12)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(tint))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
        .ignoresSafeArea()
    }
}
