import SwiftUI

// MARK: - Flow design system (v3.1)
//
// ONE design language for the whole app:
// - Content surfaces (cards, rows, panels) follow the NativeTongue template
//   (docs/DESIGN_VORLAGE.md): soft white/frosted cards with large radii on
//   the colored flow background, no border lines.
// - Controls and floating bars use macOS 26 Liquid Glass (`glassEffect`).
// - Every accent-colored element reads `\.flowAccent` — nothing hard-codes
//   a color, so the user's accent choice reaches every corner.
//
// Native controls that look foreign in content areas (segmented pickers,
// popup buttons, steppers) are wrapped here; views use these components
// instead of the raw SwiftUI controls.

// MARK: Surfaces

/// Content surface: frosted/solid card with the template's soft shadow.
struct FlowSurface: ViewModifier {
    var cornerRadius: CGFloat
    var shadow: Bool = true

    @Environment(\.surfaceLevel) private var level
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pixelMode) private var pixelMode

    func body(content: Content) -> some View {
        if pixelMode {
            content
                .background(Rectangle().fill(colorScheme == .dark ? Color(white: 0.16) : Color.white))
                .pixelFrame(true, shadow: shadow ? 4 : 0)
        } else {
            smooth(content)
        }
    }

    @ViewBuilder
    private func smooth(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let effective: SurfaceLevel = reduceTransparency ? .solid : level
        content
            .background {
                ZStack {
                    switch effective {
                    case .solid:
                        shape.fill(colorScheme == .dark ? Color(white: 0.15) : Color.white)
                    case .frosted:
                        shape.fill(.regularMaterial)
                        shape.fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.62))
                    case .clear:
                        shape.fill(.ultraThinMaterial)
                        shape.fill(colorScheme == .dark ? Color.white.opacity(0.02) : Color.white.opacity(0.28))
                    }
                }
                .shadow(color: shadow ? Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07) : .clear,
                        radius: 14, x: 0, y: 5)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.55), lineWidth: 0.7)
            }
    }
}

extension View {
    /// Card surface (rows, tiles, panels) in the current surface level.
    func flowSurface(cornerRadius: CGFloat = Theme.Radius.card, shadow: Bool = true) -> some View {
        modifier(FlowSurface(cornerRadius: cornerRadius, shadow: shadow))
    }

    /// Floating control bar / button cluster in Liquid Glass.
    func flowGlass(cornerRadius: CGFloat? = nil, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(FlowGlassModifier(cornerRadius: cornerRadius, interactive: interactive, tint: tint))
    }
}

private struct FlowGlassModifier: ViewModifier {
    var cornerRadius: CGFloat?
    var interactive: Bool
    var tint: Color?

    func body(content: Content) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return Group {
            if let cornerRadius {
                content.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.glassEffect(glass, in: Capsule())
            }
        }
    }
}

/// A plain card container (for content that isn't a single row).
struct FlowCard<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = Theme.Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flowSurface(cornerRadius: cornerRadius)
    }
}

// MARK: Sections and rows

/// Section header + stacked rows (template: "Display", "Surfaces", …).
/// The rows themselves are the cards — the section adds no box.
struct PillSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                Text(L(title))
                    .flowFont(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            if let footer {
                Text(L(footer))
                    .flowFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .id(title)
    }
}

/// One setting: title + explanation left, control right, on its own pill
/// card. Narrow widths wrap the control below the text instead of clipping
/// it (audit finding 9).
struct PillRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var help: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var control: Control

    init(title: String, subtitle: String? = nil, help: String? = nil, systemImage: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                label
                Spacer(minLength: 12)
                control.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                label
                control
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.row)
        .help(help ?? "")
    }

    private var label: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .flowFont(.title3, weight: .regular)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                    .flowFont(.body, weight: .medium)
                if let subtitle {
                    Text(L(subtitle))
                        .flowFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .layoutPriority(1)
    }
}

/// Muted grouping label inside a card (e.g. above a set of toggles).
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(L(text))
            .flowFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }
}

// MARK: Segmented pills

/// One option of a `SegmentedPills` control.
struct PillOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var shortLabel: String? = nil
    var systemImage: String? = nil
    /// Show the label as-is (language names like "Deutsch"/"English").
    var verbatim: Bool = false
    var id: Value { value }

    var displayLabel: String { verbatim ? label : L(label) }
}

/// Segmented control as connected pills: the selected segment is filled
/// with the accent and glides between options (template §6.4).
/// Falls back to short labels / icons only when space runs out.
struct SegmentedPills<Option: Hashable>: View {
    @Environment(\.pixelMode) private var pixelMode
    @Binding var selection: Option
    let options: [PillOption<Option>]
    var size: ControlSize = .regular

    @Environment(\.flowAccent) private var accent
    @Namespace private var namespace

    init(selection: Binding<Option>, options: [PillOption<Option>], size: ControlSize = .regular) {
        _selection = selection
        self.options = options
        self.size = size
    }

    /// Legacy tuple initializer.
    init(selection: Binding<Option>, options: [(value: Option, label: String)]) {
        self.init(selection: selection, options: options.map { PillOption(value: $0.value, label: $0.label) })
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            segments(compact: false)
            segments(compact: true)
        }
    }

    private func segments(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option, compact: compact)
            }
        }
        .padding(3)
        .background(flowShape(pixelMode).fill(Color.primary.opacity(0.055)))
        .overlay(flowShape(pixelMode).stroke(Color.primary.opacity(0.06), lineWidth: 0.6))
        .fixedSize()
    }

    private func segment(_ option: PillOption<Option>, compact: Bool) -> some View {
        let isSelected = option.value == selection
        let text = compact ? (option.shortLabel ?? option.label) : option.label
        return Button {
            withAnimation(Theme.Motion.flow) { selection = option.value }
        } label: {
            HStack(spacing: 6) {
                if let image = option.systemImage {
                    Image(systemName: image)
                }
                if !(compact && option.systemImage != nil && option.shortLabel == nil) {
                    Text(option.verbatim ? text : L(text)).lineLimit(1)
                }
            }
            .flowFont(size == .small ? .callout : .body, weight: isSelected ? .semibold : .regular)
            .padding(.horizontal, size == .small ? 10 : 15)
            .padding(.vertical, size == .small ? 4 : 7)
            .foregroundStyle(isSelected ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(.primary))
            .background {
                if isSelected {
                    flowShape(pixelMode)
                        .fill(accent.fill)
                        .shadow(color: accent.color.opacity(0.35), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(flowShape(pixelMode))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .help(option.displayLabel)
    }
}

// MARK: Pickers, toggles, sliders, steppers

/// Popup picker rendered as a pill (replaces grey `.menu` pickers).
struct PillPicker<Value: Hashable>: View {
    @Environment(\.pixelMode) private var pixelMode
    @Binding var selection: Value
    let options: [PillOption<Value>]
    var minWidth: CGFloat? = nil

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options) { option in
                    if let image = option.systemImage {
                        Label(option.displayLabel, systemImage: image).tag(option.value)
                    } else {
                        Text(option.displayLabel).tag(option.value)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                if let image = current?.systemImage {
                    Image(systemName: image).foregroundStyle(.tint)
                }
                Text(current?.displayLabel ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(size: 9, weight: .bold)
                    .foregroundStyle(.secondary)
            }
            .flowFont(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minWidth: minWidth, alignment: .leading)
            .background(flowShape(pixelMode).fill(Color.primary.opacity(0.055)))
            .overlay(flowShape(pixelMode).stroke(Color.primary.opacity(0.07), lineWidth: 0.6))
            .contentShape(flowShape(pixelMode))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var current: PillOption<Value>? {
        options.first { $0.value == selection }
    }
}

/// Accent-tinted switch (native Liquid Glass switch, accent track).
struct PillToggle: View {
    @Binding var isOn: Bool
    var help: String? = nil
    @Environment(\.flowAccent) private var accent

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(accent.color)
            .help(help ?? "")
    }
}

/// Slider with value readout, accent tinted.
struct PillSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var format: String = "%.2f"
    var width: CGFloat = 180
    @Environment(\.flowAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(String(format: format, value))
                .flowFont(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .tint(accent.color)
        .frame(width: width)
    }
}

/// − value + stepper as a pill (replaces the tiny native stepper arrows).
struct PillStepper: View {
    @Environment(\.pixelMode) private var pixelMode
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var suffix: String = ""

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value - step >= range.lowerBound) { value = max(range.lowerBound, value - step) }
            Text(verbatim: suffix.isEmpty ? "\(value)" : "\(value) \(L(suffix))")
                .flowFont(.body, weight: .semibold)
                .monospacedDigit()
                .frame(minWidth: 40)
                .contentTransition(.numericText(value: Double(value)))
            stepButton("plus", enabled: value + step <= range.upperBound) { value = min(range.upperBound, value + step) }
        }
        .padding(3)
        .background(flowShape(pixelMode).fill(Color.primary.opacity(0.055)))
        .animation(Theme.Motion.quick, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .appFont(size: 11, weight: .bold)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
    }
}

/// Text field as a soft inset pill (replaces bordered square fields).
struct FlowTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6))
    }
}

extension TextFieldStyle where Self == FlowTextFieldStyle {
    static var flow: FlowTextFieldStyle { FlowTextFieldStyle() }
}

/// Collapsible "Erweitert" container — closed by default.
struct DisclosurePill<Content: View>: View {
    let title: String
    var systemImage: String = "slider.horizontal.3"
    var defaultOpen = false
    @ViewBuilder var content: Content

    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Theme.Motion.flow) { isOpen.toggle() }
            } label: {
                HStack {
                    Label(L(title), systemImage: systemImage)
                        .flowFont(.body, weight: .medium)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .flowSurface(cornerRadius: Theme.Radius.row)
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 10) { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { isOpen = defaultOpen }
    }
}

// MARK: Accent swatches

/// Accent swatches in one row with labels underneath (template §6.5);
/// wraps into a grid when narrow instead of scrolling or clipping.
struct AccentSwatchPicker: View {
    @Binding var accent: AppAccent

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 6)], spacing: 14) {
            ForEach(AppAccent.allCases) { candidate in
                swatch(candidate)
            }
        }
    }

    private func swatch(_ candidate: AppAccent) -> some View {
        let isSelected = candidate == accent
        return Button {
            withAnimation(Theme.Motion.flow) { accent = candidate }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(candidate.fill)
                        .frame(width: 40, height: 40)
                        .shadow(color: candidate.color.opacity(isSelected ? 0.45 : 0.18), radius: isSelected ? 8 : 3, y: 2)
                    if isSelected {
                        Circle()
                            .strokeBorder(candidate.color, lineWidth: 2.5)
                            .frame(width: 50, height: 50)
                        Image(systemName: "checkmark")
                            .appFont(size: 14, weight: .bold)
                            .foregroundStyle(candidate.onAccent)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 52, height: 52)
                Text(candidate.displayName)
                    .flowFont(.callout, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Buttons

/// Prominent = accent gradient capsule, secondary = tinted capsule,
/// subtle = quiet text button with hover fill.
struct FlowButtonStyle: ButtonStyle {
    enum Variant {
        case prominent
        case secondary
        case subtle
        case destructive
    }
    var variant: Variant = .prominent
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        FlowButtonBody(configuration: configuration, variant: variant, size: size)
    }
}

private struct FlowButtonBody: View {
    @Environment(\.pixelMode) private var pixelMode
    let configuration: ButtonStyleConfiguration
    let variant: FlowButtonStyle.Variant
    let size: ControlSize
    @Environment(\.flowAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .flowFont(size == .large ? .headline : .body, weight: .semibold)
            .padding(.horizontal, size == .small ? 11 : (size == .large ? 22 : 16))
            .padding(.vertical, size == .small ? 5 : (size == .large ? 11 : 8))
            .foregroundStyle(foreground)
            .background(background, in: flowShape(pixelMode))
            .overlay(flowShape(pixelMode).stroke(Color.white.opacity(variant == .prominent ? 0.25 : 0), lineWidth: 0.7))
            .shadow(color: variant == .prominent ? accent.color.opacity(hovering ? 0.45 : 0.28) : .clear, radius: hovering ? 10 : 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .animation(Theme.Motion.quick, value: hovering)
            .onHover { hovering = $0 }
            .contentShape(flowShape(pixelMode))
            .pixelFrame(pixelMode && variant != .subtle, shadow: configuration.isPressed ? 0 : 2)
    }

    private var foreground: AnyShapeStyle {
        switch variant {
        case .prominent: return AnyShapeStyle(accent.onAccent)
        case .secondary: return AnyShapeStyle(accent.textColor)
        case .subtle: return AnyShapeStyle(.primary)
        case .destructive: return AnyShapeStyle(Color.red)
        }
    }

    private var background: AnyShapeStyle {
        switch variant {
        case .prominent: return AnyShapeStyle(accent.fill)
        case .secondary: return AnyShapeStyle(accent.color.opacity(hovering ? 0.2 : 0.13))
        case .subtle: return AnyShapeStyle(Color.primary.opacity(hovering ? 0.08 : 0.045))
        case .destructive: return AnyShapeStyle(Color.red.opacity(hovering ? 0.16 : 0.1))
        }
    }
}

extension ButtonStyle where Self == FlowButtonStyle {
    static var flowProminent: FlowButtonStyle { FlowButtonStyle(variant: .prominent) }
    static var flowSecondary: FlowButtonStyle { FlowButtonStyle(variant: .secondary) }
    static var flowSubtle: FlowButtonStyle { FlowButtonStyle(variant: .subtle) }
}

/// Round icon button in Liquid Glass (transport, pane toggles, overlays).
struct GlassIconButton: View {
    let systemImage: String
    var label: String
    var size: CGFloat = 34
    var isActive: Bool = false
    var action: () -> Void
    @Environment(\.flowAccent) private var accent

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .appFont(size: size * 0.42, weight: .semibold)
                .foregroundStyle(isActive ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(isActive ? .regular.tint(accent.color).interactive() : .regular.interactive(), in: Circle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Small icon that only appears while its row is hovered (row actions).
struct HoverRevealModifier: ViewModifier {
    var isVisible: Bool
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .animation(Theme.Motion.quick, value: isVisible)
    }
}

// MARK: Status, progress, stats

/// Small status chip (processing states, counts, hints).
struct StatusBadge: View {
    @Environment(\.pixelMode) private var pixelMode
    let text: String
    var systemImage: String? = nil
    var tint: Color? = nil
    @Environment(\.flowAccent) private var accent

    var body: some View {
        let color = tint ?? accent.color
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(L(text))
                .lineLimit(1)
        }
        // A badge never breaks inside; the row around it decides layout.
        .fixedSize()
        .flowFont(.caption, weight: .semibold)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: flowShape(pixelMode))
        .foregroundStyle(tint ?? accent.textColor)
    }
}

/// Rounded progress bar with the accent gradient.
struct FlowProgressBar: View {
    @Environment(\.pixelMode) private var pixelMode
    var fraction: Double
    var height: CGFloat = 8
    @Environment(\.flowAccent) private var accent

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                flowShape(pixelMode).fill(Color.primary.opacity(0.08))
                flowShape(pixelMode)
                    .fill(LinearGradient(colors: [accent.color, accent.gradientPartner], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * clamped))
                    .opacity(clamped > 0 ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: clamped)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(clamped * 100)) Prozent")
    }
}

/// Circular progress (book covers, sidebar rows, processing hero).
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 3
    var showsTrack: Bool = true
    @Environment(\.flowAccent) private var accent

    var body: some View {
        ZStack {
            if showsTrack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            }
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(AngularGradient(colors: [accent.color, accent.gradientPartner, accent.color], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: fraction)
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100)) Prozent")
    }
}

/// Metric tile: label, big value, optional detail (review / processing).
struct StatTile: View {
    let label: String
    let value: String
    var detail: String? = nil
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(.tint)
                }
                Text(L(label))
                    .foregroundStyle(.secondary)
            }
            .flowFont(.callout, weight: .medium)
            Text(value)
                .flowFont(.title2)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(L(detail))
                    .flowFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowSurface(cornerRadius: Theme.Radius.card)
    }
}

/// Centered empty / error state as a flow card (replaces bare
/// ContentUnavailableView in content areas).
struct EmptyStateCard<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 16) {
            AppIconTile(systemImage: systemImage, size: 64)
            VStack(spacing: 6) {
                Text(L(title)).flowFont(.title2)
                if let message {
                    Text(L(message))
                        .flowFont(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actions
        }
        .padding(32)
        .frame(maxWidth: 460)
        .flowSurface(cornerRadius: Theme.Radius.panel)
    }
}

extension EmptyStateCard where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// The template's gradient icon tile (page headers, empty states).
struct AppIconTile: View {
    let systemImage: String
    var size: CGFloat = 52
    @Environment(\.flowAccent) private var accent

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(accent.fill)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .appFont(size: size * 0.44, weight: .semibold)
                    .foregroundStyle(accent.onAccent)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.8)
            }
            .shadow(color: accent.color.opacity(0.35), radius: size * 0.2, y: size * 0.08)
    }
}

/// Page header: icon tile, large title, subtitle (template header).
struct PageHeader<Trailing: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Controls move under the title when the page is too narrow for
        // both on one line (header isn't time-driven, so ViewThatFits is cheap).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                titleBlock
                Spacer(minLength: 12)
                trailing
            }
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                trailing
            }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 16) {
            AppIconTile(systemImage: systemImage, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title))
                    .flowFont(.title)
                    .lineLimit(2)
                if let subtitle {
                    Text(L(subtitle))
                        .flowFont(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Stage badge

struct StageBadge: View {
    let stage: PipelineStage

    var body: some View {
        StatusBadge(text: stage.displayName, systemImage: symbolName, tint: color)
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

    private var color: Color? {
        switch stage {
        case .done: return .green
        case .failed: return .red
        default: return nil
        }
    }
}
