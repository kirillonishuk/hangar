import AppKit
import SwiftUI

/// Task-area tokens added by the polish pass (tabs, toast, terminal gutter); Theme.swift holds the rest.
extension Theme {
    /// Ghostty `window-padding-x/y`: terminal text starts at the status line's and pane header's 12 pt gutter.
    public static let terminalPaddingX = 12
    public static let terminalPaddingY = 6

    /// Toast (§3.15): shown 5 s; level-1 shadow `0 8 24 .4` (SwiftUI's radius is half the CSS blur).
    public static let toastDuration: TimeInterval = 5
    public static let toastShadow = (opacity: 0.4, radius: CGFloat(12), y: CGFloat(8))
    /// 16 above the chat area's bottom: the hosting view's margin for the shadow is counted in.
    public static let toastBottom: CGFloat = Space.s4 - toastShadow.radius

    /// Tab `×`: its hover box reaches this far around the 12 pt icon (into the tab's padding), corner radius.
    public static let tabCloseInset: CGFloat = Space.s1
    public static let tabCloseRadius: CGFloat = Radius.control
    /// Tab widths (decision #69): a crowded bar shrinks tabs to `tabMinWidth` (icon, a few letters, `×`),
    /// then scrolls; a roomy one stops them at `tabMaxWidth`.
    public static let tabMinWidth: CGFloat = 110
    public static let tabMaxWidth: CGFloat = 200
    /// A file (or diff) tab is as wide as its whole name, up to this; past it the name truncates in the middle.
    public static let fileTabMaxWidth: CGFloat = 2 * tabMaxWidth
    /// Fade over the clipped edges of a scrolled bar; a revealed tab also clears it.
    public static let tabFadeWidth: CGFloat = 24
    /// A mouse wheel notch (line) scrolls the bar this far.
    public static let tabWheelLine: CGFloat = 16
    /// While dragging a tab this close to the bar's edge, each move scrolls the bar by `tabDragScrollStep`.
    public static let tabDragScrollEdge: CGFloat = 32
    public static let tabDragScrollStep: CGFloat = 12
    /// Reorder: the slot the neighbours open for the dragged tab — `accent` outline over an `accent` tint.
    public static let tabDropSlotLineWidth: CGFloat = 2
}
