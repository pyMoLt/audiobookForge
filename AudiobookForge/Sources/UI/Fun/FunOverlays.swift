import SwiftUI
import AppKit

// MARK: - Achievement toast

/// "Achievement unlocked" — a retro box sliding up from the bottom (v4.3).
struct AchievementToast: View {
    let achievement: Achievement

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: achievement.systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(red: 0.98, green: 0.82, blue: 0.2))
                .frame(width: 40, height: 40)
                .background(Rectangle().fill(Color.black.opacity(0.35)))
                .overlay(Rectangle().strokeBorder(Color(red: 0.98, green: 0.82, blue: 0.2), lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text("Erfolg freigeschaltet")
                    .font(PixelFont.font(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.98, green: 0.82, blue: 0.2))
                    .textCase(.uppercase)
                Text(achievement.title)
                    .font(PixelFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(achievement.detail)
                    .font(PixelFont.font(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Rectangle().fill(Color(red: 0.1, green: 0.1, blue: 0.16)))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
        .background(Rectangle().fill(Color.black.opacity(0.4)).offset(x: 4, y: 4))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Owl post

/// An owl crosses the window with a letter when a book is finished; the
/// letter lands in the corner and opens the book (v4.3).
struct OwlPostOverlay: View {
    let delivery: FunCenter.OwlDelivery
    var onOpen: () -> Void
    var onDone: () -> Void

    @State private var progress: CGFloat = 0
    @State private var wingsUp = true
    @State private var letterLanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if !letterLanded {
                    VStack(spacing: -2) {
                        FunSprite(rows: wingsUp ? Sprites.owlWingsUp : Sprites.owlWingsDown, pixel: 4)
                        FunSprite(rows: Sprites.letter, pixel: 3)
                    }
                    .position(x: -60 + (geometry.size.width + 120) * progress,
                              y: 110 + sin(progress * .pi * 3) * 26)
                    .allowsHitTesting(false)
                }
                if letterLanded {
                    letterCard
                        .position(x: geometry.size.width - 190, y: geometry.size.height - 160)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .task { await fly() }
    }

    private var letterCard: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                FunSprite(rows: Sprites.letter, pixel: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Eulenpost")
                        .font(PixelFont.font(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(String(format: L("„%@“ ist fertig."), delivery.title))
                        .font(PixelFont.font(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text("Antippen zum Öffnen")
                        .font(PixelFont.font(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
            .background(Rectangle().fill(Color(nsColor: .windowBackgroundColor)))
            .pixelFrame(true)
        }
        .buttonStyle(.plain)
    }

    private func fly() async {
        guard !reduceMotion else {
            withAnimation { letterLanded = true }
            SoundFX.shared.play(.owlHoot)
            try? await Task.sleep(for: .seconds(8))
            onDone()
            return
        }
        SoundFX.shared.play(.owlHoot)
        let flap = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                wingsUp.toggle()
            }
        }
        withAnimation(.linear(duration: 3.2)) { progress = 1 }
        try? await Task.sleep(for: .seconds(3.2))
        flap.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { letterLanded = true }
        try? await Task.sleep(for: .seconds(9))
        onDone()
    }
}

// MARK: - Retro confirmation cascade

/// Pixel mode is not switched on lightly (v4.3): a stack of 1998-style
/// dialogs, each one asking a little more insistently.
struct RetroCascadeOverlay: View {
    @Environment(FunCenter.self) private var fun

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
                .onTapGesture { NSSound.beep() }
            ForEach(0..<fun.cascadeStep, id: \.self) { index in
                RetroDialog(
                    message: FunCenter.cascadeMessages[min(index, FunCenter.cascadeMessages.count - 1)],
                    isActive: index == fun.cascadeStep - 1,
                    onYes: { fun.confirmCascadeStep() },
                    onNo: { fun.cancelCascade() }
                )
                .offset(x: CGFloat(index) * 30 - 45, y: CGFloat(index) * 30 - 45)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: fun.cascadeStep)
    }
}

/// One Windows-98-like dialog: grey bevelled box, navy title bar.
struct RetroDialog: View {
    let message: String
    var isActive: Bool
    var onYes: () -> Void
    var onNo: () -> Void

    private static let face = Color(red: 0.75, green: 0.75, blue: 0.75)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 10))
                Text("AudiobookForge")
                    .font(PixelFont.font(size: 12, weight: .bold))
                Spacer()
                Text("✕")
                    .font(.system(size: 10, weight: .black))
                    .frame(width: 16, height: 14)
                    .foregroundStyle(.black)
                    .background(Self.face)
                    .modifier(Bevel())
                    .onTapGesture(perform: onNo)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(LinearGradient(colors: isActive ? [Color(red: 0, green: 0, blue: 0.5), Color(red: 0.06, green: 0.52, blue: 0.82)]
                                                        : [Color(white: 0.5), Color(white: 0.7)],
                                       startPoint: .leading, endPoint: .trailing))
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, Color(red: 0.98, green: 0.85, blue: 0.1))
                Text(message)
                    .font(PixelFont.font(size: 14, weight: .regular))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            HStack(spacing: 10) {
                Spacer()
                retroButton(L("Ja"), action: onYes).keyboardShortcut(isActive ? .defaultAction : nil)
                retroButton(L("Nein"), action: onNo).keyboardShortcut(isActive ? .cancelAction : nil)
                Spacer()
            }
            .padding(.bottom, 14)
        }
        .frame(width: 360)
        .background(Self.face)
        .modifier(Bevel())
        .background(Rectangle().fill(Color.black.opacity(0.35)).offset(x: 3, y: 3))
        .allowsHitTesting(isActive)
    }

    private func retroButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(PixelFont.font(size: 13, weight: .regular))
                .foregroundStyle(.black)
                .frame(width: 78, height: 24)
                .background(Self.face)
                .modifier(Bevel())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Light top-left, dark bottom-right edges: the 1998 3-D look.
    struct Bevel: ViewModifier {
        func body(content: Content) -> some View {
            content.overlay {
                GeometryReader { geometry in
                    let w = geometry.size.width, h = geometry.size.height
                    Path { p in p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: w, y: 0)) }
                        .stroke(Color.white, lineWidth: 2)
                    Path { p in p.move(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)) }
                        .stroke(Color(white: 0.25), lineWidth: 2)
                }
            }
        }
    }
}

// MARK: - Konami code

/// ↑↑↓↓←→←→BA anywhere in the app (v4.3). Keys still reach the app.
@MainActor
final class KonamiCodeMonitor {
    static let sequence: [UInt16] = [126, 126, 125, 125, 123, 124, 123, 124, 11, 0]
    private var monitor: Any?
    private var position = 0

    func start(onMatch: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let code = event.keyCode
            MainActor.assumeIsolated {
                if code == Self.sequence[self.position] {
                    self.position += 1
                    if self.position == Self.sequence.count {
                        self.position = 0
                        onMatch()
                    }
                } else {
                    self.position = code == Self.sequence[0] ? (self.position == 2 ? 2 : 1) : 0
                }
            }
            return event
        }
    }

    /// Pure matcher for the tests.
    static func matches(_ codes: [UInt16]) -> Bool {
        var position = 0
        for code in codes {
            if code == sequence[position] {
                position += 1
                if position == sequence.count { return true }
            } else {
                position = code == sequence[0] ? (position == 2 ? 2 : 1) : 0
            }
        }
        return false
    }
}
