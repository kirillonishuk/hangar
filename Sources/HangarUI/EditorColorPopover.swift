import AppKit
import SwiftUI
import Workspace

extension EditorColor {
    @MainActor var title: String {
        let key: L10n.Key = switch self {
        case .keyword: .edcKeyword
        case .control: .edcControl
        case .string: .edcString
        case .escape: .edcEscape
        case .regexp: .edcRegexp
        case .comment: .edcComment
        case .number: .edcNumber
        case .type: .edcType
        case .function: .edcFunction
        case .variable: .edcVariable
        case .constant: .edcConstant
        case .jsonKey: .edcJsonKey
        case .punctuation: .edcPunctuation
        case .operator: .edcOperator
        case .text: .edcText
        case .background: .edcBackground
        case .line: .edcLine
        case .selection: .edcSelection
        case .find: .edcFind
        case .gutter: .edcGutter
        case .gutterActive: .edcGutterActive
        case .cursor: .edcCursor
        case .indent: .edcIndent
        case .indentActive: .edcIndentActive
        case .whitespace: .edcWhitespace
        case .bracket1: .edcBracket1
        case .bracket2: .edcBracket2
        case .bracket3: .edcBracket3
        case .diffAddedLine: .edcDiffAddedLine
        case .diffRemovedLine: .edcDiffRemovedLine
        case .diffAddedText: .edcDiffAddedText
        case .diffRemovedText: .edcDiffRemovedText
        }
        return L10n.s(key)
    }

    /// What the group colors, in code («"utf8", значения JSON»); nil for the editor's parts.
    @MainActor var sample: String? {
        let key: L10n.Key? = switch self {
        case .keyword: .edsKeyword
        case .control: .edsControl
        case .string: .edsString
        case .escape: .edsEscape
        case .regexp: nil
        case .comment: .edsComment
        case .number: .edsNumber
        case .type: .edsType
        case .function: .edsFunction
        case .variable: .edsVariable
        case .constant: .edsConstant
        case .jsonKey: .edsJsonKey
        case .punctuation: .edsPunctuation
        case .operator: .edsOperator
        case .text: .edsText
        default: nil
        }
        return self == .regexp ? "/^[a-z-]+$/" : key.map { L10n.s($0) }
    }
}

/// A swatch: the color over a checkerboard when it is translucent.
struct EditorSwatch: View {
    let hex: String
    var size = Theme.EditorSettings.swatch

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.EditorSettings.swatchRadius)
        ZStack {
            if EditorHex.alpha(hex) < 1 {
                Canvas { ctx, s in
                    let step = Theme.EditorSettings.checker
                    for y in stride(from: 0, to: s.height, by: step) {
                        for x in stride(from: 0, to: s.width, by: step) where Int(x / step + y / step) % 2 == 0 {
                            ctx.fill(Path(CGRect(x: x, y: y, width: step, height: step)), with: .color(Theme.ui.text3))
                        }
                    }
                }
            }
            Theme.ui.editor(hex)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.ui.controlBorderStrong, lineWidth: 1))
    }
}

/// The color popover (#108, NSPopover): HEX (and opacity for colors over text), hue and lightness bars, the theme's own
/// colors, the system palette, «Сбросить». A drag shows in the preview only; the release writes the config.
struct EditorColorPopover: View {
    @Bindable var model: EditorSettingsModel
    @State private var hexText = ""
    @State private var alphaText = ""
    /// What the bars made last, so hue and saturation survive a trip to black or white.
    @State private var held: (hsl: EditorHSL, hex: String)?
    @FocusState private var focused: Bool

    private typealias S = Theme.EditorSettings

    var body: some View {
        if let color = model.editing { content(color) }
    }

    private func content(_ color: EditorColor) -> some View {
        let theme = model.theme
        let hex = theme.hex(color)
        let hsl = EditorHSL.basis(hex, held: held)
        return VStack(alignment: .leading, spacing: S.popoverGap) {
            HStack(spacing: S.popoverGap) {
                EditorSwatch(hex: hex, size: S.popoverSwatch)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: color.title).font(Theme.Typography.body.font(.semibold))
                        .foregroundStyle(Theme.ui.textStrong)
                    if let sample = color.sample {
                        Text(verbatim: sample).font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3)
                    }
                }
                .lineLimit(1)
            }
            HStack(spacing: Theme.pickGap) {
                Text(verbatim: "HEX").foregroundStyle(Theme.ui.text3)
                TextField("", text: $hexText)
                    .focused($focused)
                    .inputField(focused: focused, mono: true)
                    .frame(width: S.hexFieldWidth)
                    .onSubmit { commitText(color, hex) }
                if color.translucent {
                    Text(verbatim: "α").foregroundStyle(Theme.ui.text3).help(L10n.s(.edOpacity))
                    TextField("", text: $alphaText)
                        .inputField(focused: false, mono: true)
                        .frame(width: S.alphaFieldWidth)
                        .onSubmit { commitText(color, hex) }
                        .help(L10n.s(.edOpacity))
                    Text(verbatim: "%").foregroundStyle(Theme.ui.text3)
                }
            }
            .font(Theme.Typography.secondary.font())
            bar(hueGradient, at: hsl.h, help: L10n.s(.edHue)) { c, v in
                c.h = v
                c.s = max(c.s, 0.05)  // a grey gets a hint of the hue, or the bar would do nothing
            }
            bar(Gradient(colors: [.black, Theme.ui.editor(EditorHex.fromHSL(h: hsl.h, s: hsl.s, l: 0.5)), .white]), at: hsl.l,
                help: L10n.s(.edLightness)) { c, v in c.l = v }
            Text(verbatim: L10n.s(.edThemeColors)).font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(S.gridSwatch), spacing: S.gridGap), count: S.gridColumns),
                      alignment: .leading, spacing: S.gridGap) {
                ForEach(Self.themeColors(theme), id: \.self) { c in
                    Button { model.commit(color, EditorHex.with(c, alpha: hsl.a)) } label: {
                        EditorSwatch(hex: c, size: S.gridSwatch)
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                    .help(c)
                }
            }
            HStack(spacing: Theme.pickGap) {
                Button { model.openSystemPalette() } label: { ActionLabel(title: L10n.s(.edSystemPalette)) }
                    .buttonStyle(ActionButtonStyle())
                    .fixedSize()
                Spacer(minLength: 0)
                Button { model.reset(color) } label: { ActionLabel(title: L10n.s(.edReset), icon: .restore) }
                    .buttonStyle(HeaderActionStyle())
                    .fixedSize()
                    .disabled(!theme.changed.contains(color))
                    .help(L10n.f(.edResetTo, EditorSettingsModel.name(theme.base)))
            }
            .font(Theme.Typography.secondary.font())
        }
        .padding(S.popoverPadding)
        .frame(width: S.popoverWidth, alignment: .leading)
        .background(Theme.ui.sheet)
        .onAppear { sync(hex) }
        .onChange(of: hex) { _, new in if !focused { sync(new) } }
    }

    private func sync(_ hex: String) {
        hexText = EditorHex.with(hex, alpha: 1)
        alphaText = String(Int((EditorHex.alpha(hex) * 100).rounded()))
    }

    /// ↩ in HEX or α: a valid value is applied, anything else goes back to the current one.
    private func commitText(_ color: EditorColor, _ current: String) {
        let typed = hexText.hasPrefix("#") ? hexText : "#" + hexText
        guard let rgb = HangarConfig.normalizedHex(typed.trimmingCharacters(in: .whitespaces)) else { sync(current); return }
        // A solid color's alpha (typed as #rrggbbaa) is dropped: only colors over text are translucent.
        let alpha = color.translucent ? (Double(alphaText.trimmingCharacters(in: .whitespaces)).map { $0 / 100 } ?? EditorHex.alpha(rgb))
            : 1
        model.commit(color, EditorHex.with(rgb, alpha: alpha))
    }

    private var hueGradient: Gradient {
        Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Theme.ui.editor(EditorHex.fromHSL(h: min($0, 0.999), s: 1, l: 0.5)) })
    }

    /// A gradient bar with a knob at `value` (0…1); dragging previews, the release commits.
    private func bar(_ gradient: Gradient, at value: Double, help: String,
                     update: @escaping (inout EditorHSL, Double) -> Void) -> some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: S.barHeight)
                Circle().strokeBorder(Color.white, lineWidth: S.knobBorder)
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .frame(width: S.knob, height: S.knob)
                    .offset(x: max(0, min(w - S.knob, value * w - S.knob / 2)))
            }
            .frame(height: S.knob)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in if let (color, hex) = drag(d, width: w, update) { model.preview(color, hex) } }
                .onEnded { d in if let (color, hex) = drag(d, width: w, update) { model.commit(color, hex) } })
        }
        .frame(height: S.knob)
        .pointingHand()
        .help(help)
        .accessibilityLabel(help)
    }

    /// One step of a bar drag: from the held values (not the hex, which loses hue at black), remembered for the next.
    private func drag(_ d: DragGesture.Value, width: CGFloat, _ update: (inout EditorHSL, Double) -> Void) -> (EditorColor, String)? {
        guard let color = model.editing else { return nil }
        var c = EditorHSL.basis(model.theme.hex(color), held: held)
        update(&c, max(0, min(1, d.location.x / width)))
        let hex = c.hex
        held = (c, hex)
        return (color, hex)
    }

    /// The theme's own opaque colors, each once (picking from them keeps the palette small).
    static func themeColors(_ t: EditorTheme) -> [String] {
        var seen = Set<String>()
        return EditorColor.allCases.map { EditorHex.with(t.hex($0), alpha: 1) }.filter { seen.insert($0).inserted }
            .prefix(2 * Theme.EditorSettings.gridColumns).map { $0 }
    }
}
