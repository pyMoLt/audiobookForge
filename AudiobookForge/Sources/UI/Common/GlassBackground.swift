import SwiftUI

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

struct StageBadge: View {
    let stage: PipelineStage

    var body: some View {
        Label(stage.displayName, systemImage: symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var symbolName: String {
        switch stage {
        case .extracting: return "doc.text.magnifyingglass"
        case .describingImages: return "photo.badge.magnifyingglass"
        case .summarizing: return "text.redaction"
        case .synthesizing: return "waveform"
        case .packaging: return "shippingbox"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch stage {
        case .done: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }
}
