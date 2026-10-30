import AgentStatus
import AppKit
import SwiftUI

// The one set of controls (design-system spec §3.8–3.11, decision #112): buttons regular / small, icon buttons, chips,
// popup buttons, one segment, checkbox and switch. Sizes are tokens (`Theme.Height`, `Radius`, `Space`, `Typography`),
// colours are roles; hover and selection are instant (§2.9), the hand only over what a click would do.

extension Theme {
    /// State values of the controls (§2.8 states, §3.8 ±6 %); opacities are `Theme.Opacity`.
    enum Control {
        /// Keyboard focus ring around the `accent` edge (at `Theme.Opacity.ring`).
        static let ringWidth: CGFloat = 3
        static let hoverBrightness = 0.06
        static let pressedBrightness = -0.06
        /// Segment: track padding; the chosen item's shadow `0 1 2 .3`.
        static let segmentPadding: CGFloat = 2
        /// The track's corners are concentric with the chosen item's: its radius + the padding.
        static let segmentTrackRadius: CGFloat = Theme.Radius.segmentItem + segmentPadding
        static let segmentShadowOpacity = 0.3
        static let segmentShadowRadius: CGFloat = 1
        static let segmentShadowY: CGFloat = 1
        /// Checkbox 14, radius 4 (sheets).
        static let checkbox: CGFloat = 14
        static let checkboxRadius: CGFloat = 4
        /// Radio option (§3.11, sheets): radio 14 — off a 1.5 `text3` ring, on a 4 `accent` ring; the chosen
        /// option's fill is `accent` at .08 (a §3.11 value, not one of the §2.7 opacities).
        static let radioEdge: CGFloat = 1.5
        static let radioOnEdge: CGFloat = 4
        static let optionFill = 0.08
        /// Switch 32 × 18, knob 14 (settings).
        static let switchWidth: CGFloat = 32
        static let switchHeight: CGFloat = 18
        static let switchKnob: CGFloat = 14
    }
}

/// `control.regular` 28 (sheets, settings, toolbar) or `control.small` 22 (rows, toasts, headers).
enum ControlSize {
    case regular, small

    var height: CGFloat { self == .regular ? Theme.Height.controlRegular : Theme.Height.controlSmall }
    /// Text buttons: 12 regular, 8 small.
    var paddingH: CGFloat { self == .regular ? Theme.Space.s3 : Theme.Space.s2 }
    var type: Theme.TypeStyle { self == .regular ? Theme.Typography.body : Theme.Typography.secondary }
    /// Icon buttons: 16 in a 28 box, 14 in a 22 one.
    var icon: CGFloat { self == .regular ? Theme.Icon.toolbar : Theme.Icon.row }
}

// MARK: Buttons

/// §3.8: `primary` (`accent` + `onAccent`, one per context), `secondary` (`hover2` + `text1`), `plain` (no fill, `text2`;
/// `hover` + `text0` under the pointer), `destructive` (as secondary, `failedText`; `failed` .15 under the pointer).
/// Filled kinds go 6 % lighter under the pointer and darker pressed; disabled .4, the hand only while enabled.
struct HangarButton: ButtonStyle {
    enum Kind { case primary, secondary, plain, destructive }

    var kind: Kind = .secondary
    var size: ControlSize = .regular
    /// Disabled while its work runs (a spinner in the label): not dimmed.
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, kind: kind, size: size, busy: busy, pressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let kind: Kind
        let size: ControlSize
        let busy: Bool
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let lit = hover && enabled
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
            label
                .font(size.type.font())
                .foregroundStyle(foreground(lit))
                .lineLimit(1)
                .padding(.horizontal, size.paddingH)
                .frame(height: size.height)
                .background(shape.fill(fill(lit)).brightness(brightness(lit)))
                .contentShape(shape)
                .opacity(enabled || busy ? 1 : Theme.Opacity.inactive)
                .pointingHand(enabled)
                .onHover { hover = $0 }
        }

        private func foreground(_ lit: Bool) -> Color {
            switch kind {
            case .primary: Theme.ui.onAccent
            case .secondary: lit ? Theme.ui.text0 : Theme.ui.text1
            case .plain: lit || pressed ? Theme.ui.text0 : Theme.ui.text2
            case .destructive: Theme.ui.failedText
            }
        }

        private func fill(_ lit: Bool) -> Color {
            switch kind {
            case .primary: Theme.ui.accent
            case .secondary: Theme.ui.hover2
            case .plain: pressed ? Theme.ui.hover2 : lit ? Theme.ui.hover : .clear
            case .destructive: lit || pressed ? Theme.ui.failed.opacity(Theme.Opacity.fill) : Theme.ui.hover2
            }
        }

        private func brightness(_ lit: Bool) -> Double {
            guard kind == .primary || kind == .secondary else { return 0 }
            return pressed ? Theme.Control.pressedBrightness : lit ? Theme.Control.hoverBrightness : 0
        }
    }
}

extension ButtonStyle where Self == HangarButton {
    static func hangar(_ kind: HangarButton.Kind = .secondary, _ size: ControlSize = .regular, busy: Bool = false) -> HangarButton {
        HangarButton(kind: kind, size: size, busy: busy)
    }
}

/// A button's label: optional 12 pt glyph, gap 6, then the title.
struct ActionLabel: View {
    let title: String
    var icon: Icon?

    var body: some View {
        HStack(spacing: Theme.Space.iconGap) {
            if let icon { IconView(icon: icon, size: Theme.Icon.inline) }
            Text(title)
        }
    }
}

/// A big choice button (Claude / Codex / Терминал in an empty session or a chooser pane): `hover2`, lighter under the
/// pointer; the label brings its own size.
struct ChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
            label
                .background(shape.fill(Theme.ui.hover2)
                    .brightness(pressed ? Theme.Control.pressedBrightness : hover ? Theme.Control.hoverBrightness : 0))
                .contentShape(shape)
                .pointingHand()
                .onHover { hover = $0 }
        }
    }
}

/// Icon button (§3.8): 28 with a 16 glyph (toolbar, footer) or 22 with 14 (rows, headers); `text2`, `hover` + `text0`
/// under the pointer, `hover2` pressed or switched on. `tint` keeps its own colour (a pinned pin).
struct IconButton: View {
    let icon: Icon
    var size: ControlSize = .small
    var tint: Color?
    var on = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { IconView(icon: icon, size: size.icon) }
            .buttonStyle(IconButtonStyle(size: size, tint: tint, on: on))
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The square box of an `IconButton`; also for icon-like labels (a glyph with a badge, «−» / «+»).
struct IconButtonStyle: ButtonStyle {
    var size: ControlSize = .small
    var tint: Color?
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, size: size, tint: tint, on: on, pressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let size: ControlSize
        let tint: Color?
        let on: Bool
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let lit = hover && enabled
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
            label
                .foregroundStyle(tint ?? (lit || on ? Theme.ui.text0 : Theme.ui.text2))
                .frame(width: size.height, height: size.height)
                .background(shape.fill(pressed || on ? Theme.ui.hover2 : lit ? Theme.ui.hover : .clear))
                .contentShape(shape)
                .opacity(enabled ? 1 : Theme.Opacity.inactive)
                .pointingHand(enabled)
                .onHover { hover = $0 }
        }
    }
}

// MARK: Chips

/// Chip (§3.9): 22, padding 8, `secondary`; off — `text2` without a fill (`hover` + `text0` under the pointer); on —
/// `accentText` on `accent` .15, no border. `square` (a 22 × 22 toggle like «Aa»); `outlined` — an `accent` edge
/// (a chip being dragged). `hand` false when the owner sets its own pointer.
struct ChipStyle: ButtonStyle {
    var on: Bool
    var square = false
    var outlined = false
    var hand = true

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, style: self, pressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let style: ChipStyle
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let lit = (hover || style.outlined) && enabled && !style.on
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
            label
                .font(Theme.Typography.secondary.font())
                .foregroundStyle(style.on ? Theme.ui.accentText : lit ? Theme.ui.text0 : Theme.ui.text2)
                .lineLimit(1)
                .padding(.horizontal, style.square ? 0 : Theme.Space.s2)
                .frame(minWidth: style.square ? Theme.Height.controlSmall : nil)
                .frame(height: Theme.Height.controlSmall)
                .background(shape.fill(style.on ? Theme.ui.accent.opacity(Theme.Opacity.fill)
                                       : pressed && enabled ? Theme.ui.hover2 : lit ? Theme.ui.hover : .clear))
                .overlay(shape.strokeBorder(style.outlined ? Theme.ui.accent : .clear))
                .contentShape(shape)
                .opacity(enabled ? 1 : Theme.Opacity.inactive)
                .pointingHand(enabled && style.hand)
                .onHover { hover = $0 }
        }
    }
}

/// A mode or filter chip: `toggles` — a multi-select filter, a click on the chosen one clears it; otherwise a click on
/// the chosen one does nothing (one of a pair). Disabled .4, reason in `help`.
struct Chip: View {
    let title: String
    var icon: Icon?
    var mono = false
    let on: Bool
    var enabled = true
    var toggles = false
    let action: () -> Void

    var body: some View {
        // A real button: keyboard focus, Space / Return and VoiceOver's press work as on any button.
        Button { if toggles || !on { action() } } label: {
            HStack(spacing: Theme.Space.iconGap) {
                if let icon { IconView(icon: icon, size: Theme.Icon.inline, tint: on ? Theme.ui.accentText : nil) }
                Text(verbatim: title)
                    .font(mono ? Theme.Typography.mono.font() : Theme.Typography.secondary.font())
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(ChipStyle(on: on, hand: toggles || !on))
        .disabled(!enabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Popup button (§3.9): a value and a 12 pt chevron that open a `PopoverMenu` under it. `.small` is a chip (`on` — a set
/// filter, `clear` puts a × that resets it in place of the chevron); `.regular` is the sheet / settings drop-down:
/// 28 high, `hover2` with a `line2` edge, the value in `text1`.
struct PopupButton: View {
    let title: String
    var icon: Icon?
    var mono = false
    var size: ControlSize = .small
    var on = false
    var clear: (() -> Void)?
    var help: String?
    /// The menu, built when it opens.
    let menu: () -> PopoverMenuContent
    @State private var anchor = MenuAnchor()

    var body: some View {
        Group {
            if size == .small, let clear {
                setChip(clear)
            } else if size == .small {
                Button(action: open) { label(chevron: true) }.buttonStyle(ChipStyle(on: on)).modifier(PopupAccessibility(title: title, help: help))
            } else {
                Button(action: open) { label(chevron: true) }.buttonStyle(FieldStyle()).modifier(PopupAccessibility(title: title, help: help))
            }
        }
        .background(MenuAnchorView(anchor: anchor))
    }

    private func open() { PopoverMenu.show(menu(), below: anchor.view) }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: Theme.Space.iconGap) {
            if let icon { IconView(icon: icon, size: Theme.Icon.inline, tint: on ? Theme.ui.accentText : Theme.ui.text2) }
            Text(verbatim: title)
                .font(mono ? Theme.Typography.mono.font() : size.type.font())
                .truncationMode(.middle)
            if chevron { IconView(icon: .chevronDown, size: Theme.Icon.inline, tint: on ? Theme.ui.accentText : Theme.ui.text2) }
        }
    }

    /// A set filter: the value opens the menu, the × beside it is its own button (pointer, Tab, VoiceOver).
    private func setChip(_ clear: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.iconGap) {
            Button(action: open) { label(chevron: false) }
                .buttonStyle(.plain)
                .modifier(PopupAccessibility(title: title, help: help))
            Button(action: clear) { IconView(icon: .close, size: Theme.Icon.inline, tint: Theme.ui.accentText).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L10n.gitClearFilter)
                .accessibilityLabel(L10n.gitClearFilter)
        }
        .font(Theme.Typography.secondary.font())
        .foregroundStyle(Theme.ui.accentText)
        .lineLimit(1)
        .padding(.horizontal, Theme.Space.s2)
        .frame(height: Theme.Height.controlSmall)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.ui.accent.opacity(Theme.Opacity.fill)))
        .pointingHand()
    }

    /// Read as a pop-up: the name (its tooltip, else the value), the value when it differs, «opens a menu».
    private struct PopupAccessibility: ViewModifier {
        let title: String
        let help: String?

        func body(content: Content) -> some View {
            content
                .help(help ?? title)
                .accessibilityLabel(help ?? title)
                .accessibilityValue(help == nil ? "" : title)
                .accessibilityHint(L10n.opensMenu)
                .accessibilityAddTraits(.isButton)
        }
    }

    private struct FieldStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { FieldLook(label: configuration.label, pressed: configuration.isPressed) }
    }

    private struct FieldLook<Label: View>: View {
        let label: Label
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
            label
                .foregroundStyle(Theme.ui.text1)
                .lineLimit(1)
                .padding(.horizontal, Theme.Space.s2)
                .frame(height: Theme.Height.controlRegular)
                .background(shape.fill(Theme.ui.hover2)
                    .brightness(pressed ? Theme.Control.pressedBrightness : hover && enabled ? Theme.Control.hoverBrightness : 0))
                .overlay(shape.strokeBorder(Theme.ui.line2))
                .contentShape(shape)
                .opacity(enabled ? 1 : Theme.Opacity.inactive)
                .pointingHand(enabled)
                .onHover { hover = $0 }
        }
    }
}

// MARK: Segment

/// One part of a `Segmented`: a title, an optional 12 pt icon (with a link dot), a `caption` count after it.
struct SegmentOption<Value: Hashable> {
    let value: Value
    let title: String
    var icon: Icon?
    /// A dot on the icon's corner (a host: `done` connected, `idle` not).
    var dot: AgentState?
    /// A count after the title («Изменения 3»); `reserveBadge` keeps a two-digit room so a count never moves the parts.
    var badge: String?
    var reserveBadge = false
    var help: String?
    var accessibilityLabel: String?
    /// Opens this menu instead of choosing (a «Ещё ▾» part).
    var menu: (() -> [PopoverMenuEntry])?
}

/// The one segment (§3.10): `field` track with a `line2` edge, padding 2, radius 7; parts 22, radius 5, `secondary`;
/// the chosen one `hover2` + `text0` + a small shadow; another lights up under the pointer. Only for real choices of
/// two or more. `equal` — parts share the width (the inspector).
struct Segmented<Value: Hashable>: View {
    let selection: Value
    let options: [SegmentOption<Value>]
    /// Shown but not choosable (the control's tooltip says why).
    var disabled: [Value] = []
    var equal = false
    let choose: (Value) -> Void

    init(selection: Value, options: [SegmentOption<Value>], disabled: [Value] = [], equal: Bool = false, choose: @escaping (Value) -> Void) {
        self.selection = selection
        self.options = options
        self.disabled = disabled
        self.equal = equal
        self.choose = choose
    }

    /// Plain titled parts.
    init(selection: Value, options: [(Value, String)], disabled: [Value] = [], choose: @escaping (Value) -> Void) {
        self.init(selection: selection, options: options.map { SegmentOption(value: $0.0, title: $0.1) }, disabled: disabled, choose: choose)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Control.segmentTrackRadius)
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                SegmentPart(option: o, on: o.value == selection, enabled: !disabled.contains(o.value), equal: equal) { choose(o.value) }
            }
        }
        .padding(Theme.Control.segmentPadding)
        .fixedSize(horizontal: !equal, vertical: true)
        .background(shape.fill(Theme.ui.field))
        .overlay(shape.strokeBorder(Theme.ui.line2))
    }
}

private struct SegmentPart<Value: Hashable>: View {
    let option: SegmentOption<Value>
    let on: Bool
    let enabled: Bool
    let equal: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        let lit = hover && enabled && !on
        let tint = on || lit ? Theme.ui.text0 : Theme.ui.text2
        Button {
            if let menu = option.menu { PopoverMenu.show(menu(), below: anchor.view) } else if !on { action() }
        } label: {
            HStack(spacing: Theme.Space.iconGap) {
                if let icon = option.icon {
                    IconView(icon: icon, size: Theme.Icon.inline, tint: tint)
                        .overlay(alignment: .bottomTrailing) {
                            if let dot = option.dot {
                                StatusDot(state: dot, size: Theme.Icon.tabDot, border: Theme.ui.field, borderWidth: Theme.Control.segmentPadding)
                                    .offset(x: Theme.Control.segmentPadding, y: Theme.Control.segmentPadding)
                            }
                        }
                }
                Text(verbatim: option.title).lineLimit(1).truncationMode(.tail)
                if let badge = option.badge {
                    Text(verbatim: badge).font(Theme.Typography.caption.font().monospacedDigit()).foregroundStyle(Theme.ui.text3)
                        .fixedSize()
                }
                if option.menu != nil { IconView(icon: .chevronDown, size: Theme.Icon.inline, tint: tint) }
            }
            .font(Theme.Typography.secondary.font())
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.s2)
            .frame(minWidth: option.reserveBadge ? reserved : nil, maxWidth: equal ? .infinity : nil)
            .frame(height: Theme.Height.controlSmall)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.segmentItem)
                .fill(on ? Theme.ui.hover2 : lit ? Theme.ui.hover : .clear)
                .shadow(color: .black.opacity(on ? Theme.Control.segmentShadowOpacity : 0),
                        radius: Theme.Control.segmentShadowRadius, y: Theme.Control.segmentShadowY))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Opacity.inactive)
        .pointingHand(enabled && (!on || option.menu != nil))
        .onHover { hover = $0 }
        .help(option.help ?? "")
        .accessibilityLabel(option.accessibilityLabel ?? option.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Title + gap + a two-digit count + side paddings («99+» may grow it a little).
    private var reserved: CGFloat {
        let width = { (s: String, f: NSFont) in ceil((s as NSString).size(withAttributes: [.font: f]).width) }
        let digits = NSFont.monospacedDigitSystemFont(ofSize: Theme.Typography.caption.size, weight: .regular)
        return width(option.title, Theme.Typography.secondary.nsFont()) + Theme.Space.iconGap + width("00", digits) + Theme.Space.s2 * 2
    }
}

/// The Changes count in a segment: none at 0, «99+» past 99.
func segmentBadge(_ count: Int) -> String? {
    count <= 0 ? nil : count > 99 ? "99+" : String(count)
}

// MARK: Checkbox, switch

/// Checkbox (§3.11, sheets): 14, radius 4; on — `accent` with an `onAccent` tick; off — `field` with a `line2` edge.
/// `label` is always its accessible name; `showsLabel` false when the row already shows it (a card row's title).
struct Checkbox: View {
    let label: String
    var showsLabel = true
    /// Shown `mono` after the label («Подготовить копию: pnpm install»).
    var detail: String?
    let on: Bool
    let toggle: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ label: String, showsLabel: Bool = true, detail: String? = nil, on: Bool, toggle: @escaping (Bool) -> Void) {
        self.label = label
        self.showsLabel = showsLabel
        self.detail = detail
        self.on = on
        self.toggle = toggle
    }

    init(_ label: String, showsLabel: Bool = true, detail: String? = nil, isOn: Binding<Bool>) {
        self.init(label, showsLabel: showsLabel, detail: detail, on: isOn.wrappedValue) { isOn.wrappedValue = $0 }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Control.checkboxRadius)
        Button { toggle(!on) } label: {
            HStack(spacing: Theme.Space.s2) {
                ZStack {
                    shape.fill(on ? Theme.ui.accent : Theme.ui.field)
                    shape.strokeBorder(on ? .clear : Theme.ui.line2)
                    if on { IconView(icon: .check, size: Theme.Icon.inline, tint: Theme.ui.onAccent) }
                }
                .frame(width: Theme.Control.checkbox, height: Theme.Control.checkbox)
                if showsLabel { Text(verbatim: detail == nil ? label : label + ":").foregroundStyle(Theme.ui.text1) }
                if let detail {
                    Text(verbatim: detail).font(Theme.Typography.mono.font()).foregroundStyle(Theme.ui.text0)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : Theme.Opacity.inactive)
        .pointingHand(enabled)
        .accessibilityLabel(detail.map { label + ": " + $0 } ?? label)
        .accessibilityValue(on ? L10n.toggleOn : L10n.toggleOff)
        .accessibilityAddTraits(.isToggle)
    }
}

/// Radio option (§3.11, sheets): a card — radio 14, title `body` 600, detail `secondary` `text2`; the chosen one has an
/// `accent` edge on `accent` .08. Dims itself when disabled (once: callers put `.disabled` on it, no opacity). Not
/// focusable itself: its group is the Tab stop and draws the ring through `focused`.
struct RadioOption: View {
    let title: String
    let detail: AttributedString
    let selected: Bool
    /// The group has keyboard focus and this is its choice: the focus ring (§2.8) around the card.
    var focused = false
    let choose: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.popover)
        Button(action: choose) {
            HStack(alignment: .top, spacing: Theme.Space.s2) {
                Circle()
                    .strokeBorder(selected ? Theme.ui.accent : Theme.ui.text3,
                                  lineWidth: selected ? Theme.Control.radioOnEdge : Theme.Control.radioEdge)
                    .background(Circle().fill(selected ? Theme.ui.onAccent : .clear))
                    .frame(width: Theme.Control.checkbox, height: Theme.Control.checkbox)
                    .padding(.top, (Theme.Typography.body.lineHeight - Theme.Control.checkbox) / 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title).font(Theme.Typography.body.font(.semibold)).foregroundStyle(Theme.ui.text0)
                    Text(detail).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text2)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.s3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(selected ? Theme.ui.accent.opacity(Theme.Control.optionFill) : .clear))
            .overlay(shape.strokeBorder(selected ? Theme.ui.accent : Theme.ui.line2))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.popover + Theme.Control.ringWidth)
                    .strokeBorder(Theme.ui.accent.opacity(Theme.Opacity.ring), lineWidth: Theme.Control.ringWidth)
                    .padding(-Theme.Control.ringWidth)
                    .opacity(focused ? 1 : 0)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .opacity(enabled ? 1 : Theme.Opacity.inactive)
        .pointingHand(enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(String(detail.characters))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Switch (§3.11, settings only, «on/off at once»): 32 × 18, knob 14; on — `accent` with an `onAccent` knob, off —
/// `hover2` with a `text2` knob. The whole switch is the button; no slide (§2.9).
struct CardSwitch: View {
    let on: Bool
    let toggle: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    init(on: Bool, toggle: @escaping (Bool) -> Void) {
        self.on = on
        self.toggle = toggle
    }

    init(isOn: Binding<Bool>) {
        self.init(on: isOn.wrappedValue) { isOn.wrappedValue = $0 }
    }

    var body: some View {
        let inset = (Theme.Control.switchHeight - Theme.Control.switchKnob) / 2
        Button { toggle(!on) } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.ui.accent : Theme.ui.hover2)
                Circle().fill(on ? Theme.ui.onAccent : Theme.ui.text2)
                    .frame(width: Theme.Control.switchKnob, height: Theme.Control.switchKnob)
                    .padding(.horizontal, inset)
            }
            .frame(width: Theme.Control.switchWidth, height: Theme.Control.switchHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : Theme.Opacity.inactive)
        .pointingHand(enabled)
        .accessibilityValue(on ? L10n.toggleOn : L10n.toggleOff)
    }
}
