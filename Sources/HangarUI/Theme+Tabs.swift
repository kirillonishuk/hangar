import AppKit
import SwiftUI

/// Task-area tokens added by the polish pass (tabs, toast, terminal gutter); Theme.swift holds the rest.
extension Theme {
    /// Ghostty `window-padding-x/y`: terminal text starts at the status line's and pane header's 12 pt gutter.
    public static let terminalPaddingX = 12
    public static let terminalPaddingY = 6

    /// Archive undo toast: shown 5 s, gap above the status line, inner paddings.
    public static let toastDuration: TimeInterval = 5
    public static let toastBottom: CGFloat = 14
    public static let toastGap: CGFloat = 10
    public static let toastPaddingH: CGFloat = 16
    public static let toastPaddingV: CGFloat = 6
    public static let toastButtonPaddingH: CGFloat = 10

    /// Tab `×`: its hover box reaches this far around the 10 pt icon (into the tab's padding), corner radius.
    public static let tabCloseInset: CGFloat = 3
    public static let tabCloseRadius: CGFloat = 4
    /// The tab being dragged is dimmed to this.
    public static let tabDragOpacity: Double = 0.6
    /// Diff lines: hover overlay of `hover` at this strength (over the add/del tint).
    public static let diffHoverOpacity: Double = 0.5
}
