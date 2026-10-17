import AppKit
import SwiftUI

/// Colors and sizes from docs/design/DESIGN.md. UI code must use these, not literals.
public enum Theme {
    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1)
    }

    // NSColor
    public static let bg = ns(0x1e1f24)
    public static let sidebar = ns(0x1a1b1f)
    public static let panel = ns(0x282a31)
    public static let line = ns(0x2a2c33)
    public static let control = ns(0x3a3d47)
    public static let field = ns(0x1b1c21)
    public static let text = ns(0xc9ccd3)
    public static let textStrong = ns(0xe6e8ee)
    public static let textRow = ns(0xb9bcc4)
    public static let text2 = ns(0x8b8f99)
    public static let text3 = ns(0x6c707a)
    public static let selection = ns(0x2c3a52)
    public static let accent = ns(0x61afef)
    public static let primary = ns(0x3b82f6)

    public static let working = ns(0x5ac8fa)
    public static let waiting = ns(0xffb340)
    public static let done = ns(0x32d74b)
    public static let failed = ns(0xff453a)
    public static let idle = ns(0x636366)

    // SwiftUI
    public enum ui {
        public static let bg = Color(nsColor: Theme.bg)
        public static let sidebar = Color(nsColor: Theme.sidebar)
        public static let panel = Color(nsColor: Theme.panel)
        public static let line = Color(nsColor: Theme.line)
        public static let control = Color(nsColor: Theme.control)
        public static let field = Color(nsColor: Theme.field)
        public static let text = Color(nsColor: Theme.text)
        public static let textStrong = Color(nsColor: Theme.textStrong)
        public static let textRow = Color(nsColor: Theme.textRow)
        public static let text2 = Color(nsColor: Theme.text2)
        public static let text3 = Color(nsColor: Theme.text3)
        public static let selection = Color(nsColor: Theme.selection)
        public static let accent = Color(nsColor: Theme.accent)
        public static let primary = Color(nsColor: Theme.primary)
        public static let working = Color(nsColor: Theme.working)
        public static let waiting = Color(nsColor: Theme.waiting)
        public static let done = Color(nsColor: Theme.done)
        public static let failed = Color(nsColor: Theme.failed)
        public static let idle = Color(nsColor: Theme.idle)
    }

    // Sizes
    public static let sidebarWidth: CGFloat = 220
    public static let sidebarMin: CGFloat = 180
    public static let sidebarMax: CGFloat = 320
    public static let tabBarHeight: CGFloat = 38
    public static let trafficLightsHeight: CGFloat = 38
    public static let windowRadius: CGFloat = 12
}
