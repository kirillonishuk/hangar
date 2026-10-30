import AppKit
import SwiftUI

/// The one text-input look (DESIGN.md «Поля ввода»): every TextField / search field / inline rename goes through it.
extension Theme {
    public enum Input {
        public static let height: CGFloat = 28
        public static let paddingH: CGFloat = 9
        /// Multi-line field: its first line sits where a single-line field's text does.
        public static let paddingV: CGFloat = 5
        public static let radius: CGFloat = 7
        public static let border: CGFloat = 1
        public static let focusRing: CGFloat = 3
        /// Search glyph before the text, and the gap after it.
        public static let iconSize: CGFloat = 14
        public static let iconGap: CGFloat = 6
        /// Inline rename: the box grows this far around the label it replaces (no jump on F2).
        public static let inlinePaddingH: CGFloat = 4

        /// One size for typed text and placeholders (`body`); `mono` only for paths, branches and commands.
        public static func font(mono: Bool = false) -> Font { (mono ? Theme.Typography.mono : Theme.Typography.body).font() }
        public static func nsFont(mono: Bool = false) -> NSFont {
            (mono ? Theme.Typography.mono : Theme.Typography.body).nsFont()
        }
    }
}

extension Theme.ui {
    static var inputBackground: Color { field }
    static var inputText: Color { text0 }
    static var inputPlaceholder: Color { text3 }
    static var inputBorder: Color { line2 }
    static var inputFocus: Color { accent }
    static var inputError: Color { failed }
}

/// `field` fill, 1 pt `line2` border, radius 7, height 28, side padding 9, `sheetRow` text; focused → `accent` border
/// + 3 pt ring, invalid → `failed`, disabled → .4. Placeholder drawn here in `text3` (a prompt's colour is lost under
/// `foregroundStyle`). `inline` (rename in a row) keeps the row's font and height and grows outwards instead.
struct InputField: ViewModifier {
    var focused: Bool
    var mono = false
    var invalid = false
    var multiline = false
    var inline = false
    var icon: Icon? = nil
    var placeholder: String? = nil
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Input.radius)
        let edge = invalid ? Theme.ui.inputError : focused ? Theme.ui.inputFocus : Theme.ui.inputBorder
        return text(content)
            .padding(.leading, icon == nil ? 0 : Theme.Input.iconSize + Theme.Input.iconGap)
            .overlay(alignment: .leading) {
                if let icon {
                    IconView(icon: icon, size: Theme.Input.iconSize, tint: focused ? Theme.ui.text2 : Theme.ui.text3)
                }
            }
            .padding(.horizontal, inline ? Theme.Input.inlinePaddingH : Theme.Input.paddingH)
            .padding(.vertical, multiline ? Theme.Input.paddingV : 0)
            .frame(minHeight: inline ? nil : Theme.Input.height, alignment: multiline ? .topLeading : .leading)
            .background(shape.fill(Theme.ui.inputBackground))
            .overlay(shape.strokeBorder(edge, lineWidth: Theme.Input.border))
            .background(RoundedRectangle(cornerRadius: Theme.Input.radius + Theme.Input.focusRing)
                .fill(edge.opacity(focused && !inline ? Theme.Opacity.ring : 0))
                .padding(-Theme.Input.focusRing))
            .padding(.horizontal, inline ? -Theme.Input.inlinePaddingH : 0)
            .opacity(enabled ? 1 : Theme.Opacity.inactive)
            .textCursor()
            .animation(Motion.ease(Theme.hoverFade), value: focused)
    }

    @ViewBuilder private func text(_ content: Content) -> some View {
        if inline {
            content.textFieldStyle(.plain).foregroundStyle(Theme.ui.inputText).lineLimit(1)
        } else {
            content
                .textFieldStyle(.plain)
                .font(Theme.Input.font(mono: mono))
                .foregroundStyle(Theme.ui.inputText)
                .overlay(alignment: multiline ? .topLeading : .leading) {
                    if let placeholder {
                        Text(verbatim: placeholder)  // prose, so never mono
                            .font(Theme.Input.font())
                            .foregroundStyle(Theme.ui.inputPlaceholder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
    }
}

extension View {
    /// The app's one input look; `placeholder` only while the text is empty (pass nil otherwise).
    func inputField(focused: Bool, mono: Bool = false, invalid: Bool = false, multiline: Bool = false,
                    icon: Icon? = nil, placeholder: String? = nil) -> some View {
        modifier(InputField(focused: focused, mono: mono, invalid: invalid, multiline: multiline, icon: icon, placeholder: placeholder))
    }
}
