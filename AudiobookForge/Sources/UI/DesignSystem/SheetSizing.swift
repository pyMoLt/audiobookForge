import SwiftUI
import AppKit

/// Sheets (v4.2.2): SwiftUI presents sheets on macOS without a resize
/// handle. `resizableSheet` opens a dialog at its preferred size (shrunk to
/// the window it covers), lets the user drag it larger or down to a floor,
/// and lays the content out flexibly in between.
enum SheetSizing {
    static var windowSize: CGSize {
        let window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }
        return window?.contentLayoutRect.size ?? CGSize(width: 1100, height: 860)
    }

    /// Opening size: `preferred`, but at most the window minus a margin, at least `floor`.
    static func openingSize(preferred: CGSize, floor: CGSize, window: CGSize = windowSize) -> CGSize {
        CGSize(width: max(floor.width, min(preferred.width, window.width - 80)),
               height: max(floor.height, min(preferred.height, window.height - 80)))
    }
}

extension View {
    /// Frame + resize handle for a sheet (see `SheetSizing`).
    func resizableSheet(preferred: CGSize, floor: CGSize) -> some View {
        let opening = SheetSizing.openingSize(preferred: preferred, floor: floor)
        return frame(minWidth: floor.width, idealWidth: opening.width, maxWidth: .infinity,
                     minHeight: floor.height, idealHeight: opening.height, maxHeight: .infinity)
            .background(SheetWindowResizer(opening: opening, floor: floor))
    }
}

/// Makes the hosting sheet window resizable once it is attached.
private struct SheetWindowResizer: NSViewRepresentable {
    let opening: CGSize
    let floor: CGSize

    func makeNSView(context: Context) -> ResizerView { ResizerView(opening: opening, floor: floor) }
    func updateNSView(_ nsView: ResizerView, context: Context) {}

    final class ResizerView: NSView {
        private let opening: CGSize
        private let floor: CGSize
        private var configured = false

        init(opening: CGSize, floor: CGSize) {
            self.opening = opening
            self.floor = floor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The sheet is attached to its parent only after this call.
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }

        private func configure() {
            guard !configured, let window, window.sheetParent != nil || window.isSheet else { return }
            configured = true
            window.styleMask.insert(.resizable)
            window.contentMinSize = floor
            window.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.setContentSize(opening)
        }
    }
}
