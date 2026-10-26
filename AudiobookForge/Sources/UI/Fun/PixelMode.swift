import SwiftUI
import CoreText

/// Pixel mode (v4.3): the whole app in an old-game look — a pixel font,
/// sharp corners, hard borders and shadows. Off by default; switched on
/// only through the confirmation cascade (or the Konami code).
extension EnvironmentValues {
    @Entry var pixelMode: Bool = false
}

enum PixelFont {
    /// Pixelify Sans (SIL Open Font License 1.1), bundled in Resources/Fonts.
    static let family = "Pixelify Sans"

    static func register() {
        guard let url = Bundle.main.url(forResource: "PixelifySans", withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: "PixelifySans", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(size: CGFloat, weight: Font.Weight) -> Font {
        .custom(family, size: size * 1.08).weight(weight)
    }
}

/// Capsules become sharp rectangles in pixel mode.
func flowShape(_ pixelMode: Bool) -> AnyShape {
    pixelMode ? AnyShape(Rectangle()) : AnyShape(Capsule())
}

extension View {
    /// A fixed-size font that follows pixel mode (replaces `.font(.system(size:…))`).
    func appFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(size: size, weight: weight, design: design))
    }

    /// Hard 2-pt border and offset shadow — the pixel version of a card edge.
    func pixelFrame(_ active: Bool, shadow: CGFloat = 4) -> some View {
        overlay { if active { Rectangle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 2) } }
            .background { if active { Rectangle().fill(Color.primary.opacity(0.28)).offset(x: shadow, y: shadow) } }
    }
}

private struct AppFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.pixelMode) private var pixelMode

    func body(content: Content) -> some View {
        content.font(pixelMode ? PixelFont.font(size: size, weight: weight) : .system(size: size, weight: weight, design: design))
    }
}
