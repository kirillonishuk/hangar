import SwiftUI

// One control language (controls-v2.html, B′ «Мягкие заливки», decision #106): a filled `primary` button for the one
// main action of a row or toast; `button` fill for the rest; modes are Git-filter chips; header actions stay unfilled
// until hovered; links stay `accentText`; hints are `text3` and never clickable. Keys go only into tooltips.

/// Row / toast action, 22 high: `primary` for the row's one main action, otherwise `button` → `moreBg` under the
/// pointer; pressed darker, disabled .38, hand only while enabled. `destructive` (a trash icon): `failedText` when hovered.
struct ActionButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, primary: primary, destructive: destructive, pressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let primary: Bool
        let destructive: Bool
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let lit = hover && enabled
            label
                .font(.system(size: Theme.Control.font, weight: .medium))
                .foregroundStyle(primary ? Theme.ui.primaryText : lit && destructive ? Theme.ui.failedText : lit ? Theme.ui.textStrong : Theme.ui.text)
                .lineLimit(1)
                .padding(.horizontal, Theme.Control.paddingH)
                .frame(height: Theme.Control.height)
                .background(RoundedRectangle(cornerRadius: Theme.Control.radius)
                    .fill(primary ? Theme.ui.primary : lit || pressed ? Theme.ui.moreBg : Theme.ui.button)
                    .brightness(pressed ? Theme.Control.pressedBrightness : primary && lit ? Theme.Control.hoverBrightness : 0))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Control.radius))
                .opacity(enabled ? 1 : Theme.inactiveOpacity)
                .pointingHand(enabled)
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        }
    }
}

/// A big choice button (Claude / Codex / Терминал in an empty session or a chooser pane): `button` → `moreBg`, radius 7;
/// the label brings its own padding.
struct ChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        @State private var hover = false

        var body: some View {
            label
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .fill(hover || pressed ? Theme.ui.moreBg : Theme.ui.button)
                    .brightness(pressed ? Theme.Control.pressedBrightness : 0))
                .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
                .pointingHand()
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        }
    }
}

/// An action button's label: optional 12 pt glyph, then the title.
struct ActionLabel: View {
    let title: String
    var icon: Icon?

    var body: some View {
        HStack(spacing: Theme.Control.iconGap) {
            if let icon { IconView(icon: icon, size: Theme.Control.icon) }
            Text(title)
        }
    }
}

/// Section-header action («Очистить», «Обновить», status-bar counters): no fill at rest, `hoverStrong` under the
/// pointer, text `text2` → `textStrong`.
struct HeaderActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let lit = hover && enabled
            label
                .foregroundStyle(lit ? Theme.ui.textStrong : Theme.ui.text2)
                .lineLimit(1)
                .padding(.horizontal, Theme.Control.headerPaddingH)
                .frame(height: Theme.Control.height)
                .background(RoundedRectangle(cornerRadius: Theme.Control.radius)
                    .fill(lit || pressed ? Theme.ui.hoverStrong : .clear))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Control.radius))
                .opacity(enabled ? 1 : Theme.inactiveOpacity)
                .pointingHand(enabled)
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        }
    }
}

/// A mode or filter chip, 24 — the Git tab's filter chip: the chosen one `accent` 14 % with an `accent` 25 % border and
/// `accentText`; another is a plain label that gets a `hover` fill under the pointer. Disabled .38, reason in `help`.
struct ModeChip: View {
    let title: String
    var icon: Icon?
    var mono = false
    let on: Bool
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        // A real (plain) button: keyboard focus, Space / Return and VoiceOver's press work as on any button.
        Button { if enabled && !on { action() } } label: {
            HStack(spacing: Theme.Control.iconGap) {
                if let icon { IconView(icon: icon, size: Theme.GitTab.chipIcon, tint: tint) }
                Text(verbatim: title)
                    .font(.system(size: Theme.fontSize.footer, design: mono ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.GitTab.chipLeading)
            .frame(height: Theme.GitTab.chipHeight)
            .background(RoundedRectangle(cornerRadius: Theme.GitTab.chipRadius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.GitTab.chipRadius)
                .stroke(on ? Theme.ui.accent.opacity(Theme.GitTab.chipBorderOpacity) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.inactiveOpacity)
        .pointingHand(enabled && !on)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var lit: Bool { hover && enabled && !on }
    private var tint: Color { on ? Theme.ui.accentText : lit ? Theme.ui.text : Theme.ui.text2 }
    private var fill: Color { on ? Theme.ui.accent.opacity(Theme.GitTab.chipOnOpacity) : lit ? Theme.ui.hover : .clear }
}
