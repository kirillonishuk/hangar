import AgentStatus
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

    // NSColor — navy palette (decision #36)
    public static let bg = ns(0x121826)          // window, titlebar, tab bar, terminal area, inspector
    public static let sidebar = ns(0x20293a)
    public static let panel = ns(0x121826)       // terminal area
    public static let activeSegment = ns(0x1d2533)  // active tab / segment
    public static let line = ns(0x1b212f)
    public static let bottomBar = ns(0x212936)
    public static let control = ns(0x2b3444)
    public static let field = ns(0x121826)
    public static let text = ns(0xe6e8ee)
    public static let textStrong = ns(0xffffff)
    public static let textRow = ns(0xe6e8ee)
    public static let text2 = ns(0x8a93a6)
    public static let text3 = ns(0x5f687a)
    public static let selection = ns(0x333b4b)
    public static let accent = ns(0x61afef)
    public static let primary = ns(0x3b82f6)

    public static let working = ns(0x5ac8fa)
    public static let waiting = ns(0xffb340)
    public static let done = ns(0x32d74b)
    public static let failed = ns(0xff453a)
    public static let idle = ns(0x636366)

    public static let lineSheet = ns(0x2b3444)
    public static let sheetBorder = ns(0x2b3444)
    public static let controlBorderStrong = ns(0x3a4456)
    public static let sheet = ns(0x20293a)
    public static let sheetText = ns(0xffffff)
    public static let selectionText = ns(0xffffff)
    public static let hover = ns(0x1d2533)
    public static let hoverStrong = ns(0x2b3444)  // "+ New Task" button
    public static let pressed = ns(0x192030)
    public static let button = ns(0x2b3444)
    public static let claudeBrand = ns(0xd97757)
    /// Terminal background handed to Ghostty unless the user's Ghostty config sets one.
    public static let terminalBackgroundHex = "121826"

    // SwiftUI
    public enum ui {
        public static let bg = Color(nsColor: Theme.bg)
        public static let sidebar = Color(nsColor: Theme.sidebar)
        public static let panel = Color(nsColor: Theme.panel)
        public static let activeSegment = Color(nsColor: Theme.activeSegment)
        public static let bottomBar = Color(nsColor: Theme.bottomBar)
        public static let hoverStrong = Color(nsColor: Theme.hoverStrong)
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
        public static func status(_ state: AgentState) -> Color {
            switch state {
            case .working: working
            case .waiting: waiting
            case .done: done
            case .failed: failed
            case .idle: idle
            }
        }
        public static let lineSheet = Color(nsColor: Theme.lineSheet)
        public static let sheetBorder = Color(nsColor: Theme.sheetBorder)
        public static let sheet = Color(nsColor: Theme.sheet)
        public static let sheetText = Color(nsColor: Theme.sheetText)
        public static let selectionText = Color(nsColor: Theme.selectionText)
        public static let hover = Color(nsColor: Theme.hover)
        public static let pressed = Color(nsColor: Theme.pressed)
        public static let button = Color(nsColor: Theme.button)
        public static let controlBorderStrong = Color(nsColor: Theme.controlBorderStrong)
    }

    // Font sizes (pt)
    public enum fontSize {
        // Type scale +1 over the mockups (decision #34).
        public static let base: CGFloat = 13
        public static let row: CGFloat = 13
        public static let sheetRow: CGFloat = 13.5
        public static let taskName: CGFloat = 15
        public static let sheetTitle: CGFloat = 14.5
        public static let tabTaskTitle: CGFloat = 13
        public static let tab: CGFloat = 12.5
        public static let footer: CGFloat = 12
        public static let small: CGFloat = 11
        public static let counter: CGFloat = 11.5
        // Sidebar, as in Pane: section headers, rows, bottom buttons.
        public static let section: CGFloat = 11.5
        public static let sidebarRow: CGFloat = 13.5
        public static let sidebarFooter: CGFloat = 13
        public static let projectTracking: CGFloat = 0.06  // em
    }

    // Sizes
    public static let sidebarWidth: CGFloat = 220
    public static let sidebarMin: CGFloat = 180
    public static let sidebarMax: CGFloat = 320
    public static let tabBarHeight: CGFloat = 34
    public static let titleBarHeight: CGFloat = 38
    /// Hit area of titlebar buttons (inspector toggle).
    public static let titleButtonSize: CGFloat = 28
    public static let trafficLightsHeight: CGFloat = 38
    public static let windowRadius: CGFloat = 12
    public static let windowSize = NSSize(width: 1200, height: 760)
    public static let windowMinSize = NSSize(width: 800, height: 500)
    public static let sidebarRailWidth: CGFloat = 44
    public static let statusBarHeight: CGFloat = 22
    /// Bottom terminal drawer: bar height, grab strip on its top edge, height limits, open/close animation.
    public static let drawerBarHeight: CGFloat = 26
    public static let drawerGrabHeight: CGFloat = 5
    public static let drawerMaxFraction: CGFloat = 0.7
    public static let drawerAnimation: Double = 0.18

    public static let statusDot: CGFloat = 8
    /// `waiting` halo: ring of `waiting` at 25%.
    public static let haloWidth: CGFloat = 3
    public static let haloOpacity = 0.25
    /// Rail monogram's corner dot and its `sidebar` border.
    public static let railDot: CGFloat = 7
    public static let railDotBorder: CGFloat = 1.5
    public static let worktreeEndIcon: CGFloat = 12
    public static let rowPaddingH: CGFloat = 14
    public static let taskRowPaddingV: CGFloat = 5
    public static let projectHeaderTop: CGFloat = 6
    public static let projectHeaderBottom: CGFloat = 3
    public static let projectGap: CGFloat = 8
    public static let footerPaddingV: CGFloat = 8
    public static let tabPaddingV: CGFloat = 6
    public static let tabPaddingH: CGFloat = 14
    public static let tabGap: CGFloat = 2
    public static let tabRadius: CGFloat = 6
    /// Inline rename field in a tab.
    public static let tabRenameWidth: CGFloat = 140
    public static let renamePaddingH: CGFloat = 4
    /// Insertion line while dragging rows (`accent`).
    public static let dropLineWidth: CGFloat = 2
    /// Pointer travel before a press becomes a drag.
    public static let dragThreshold: CGFloat = 4
    public static let tabMaxChars = 32
    public static let tabTitleLeading: CGFloat = 8
    public static let tabTitleTrailing: CGFloat = 10
    public static let railRowHeight: CGFloat = 32
    public static let iconSize: CGFloat = 15
    public static let iconGap: CGFloat = 6
    public static let smallIconSize: CGFloat = 10
    /// Leading gutter of every sidebar row; its marker (dot/icon) is centered at `gutterMarkerX` in both modes.
    public static let sidebarGutter: CGFloat = 44
    public static let gutterMarkerX: CGFloat = 20
    public static let gutterTextX: CGFloat = 32
    public static let railTextX: CGFloat = 27
    public static let sectionTextX: CGFloat = 10
    public static let projectChevronX: CGFloat = 10
    public static let projectTextX: CGFloat = 20
    public static let sectionGap: CGFloat = 10
    public static let projectRowHeight: CGFloat = 32
    public static let footerRowHeight: CGFloat = 28
    public static let sidebarAnimation: Double = 0.18
    public static let hoverFade: Double = 0.12
    public static let selectionFade: Double = 0.15
    public static let pulseDuration: Double = 0.4
    public static let pulseScale: CGFloat = 1.6
    public static let projectTileSize: CGFloat = 24
    public static let projectTileRadius: CGFloat = 6
    public static let railItemRadius: CGFloat = 6
    public static let railInset: CGFloat = 4
    public static let closeOpacity: Double = 0.4
    public static let paneHeaderPaddingV: CGFloat = 5
    public static let paneHeaderPaddingH: CGFloat = 12
    public static let inactiveOpacity: Double = 0.38
    public static let disabledButtonOpacity: Double = 0.45

    public static let sheetWidth: CGFloat = 580
    /// Initial sheet height; SwiftUI content resizes the sheet.
    public static let sheetPlaceholderHeight: CGFloat = 200
    public static let sheetPaddingH: CGFloat = 18
    public static let sheetRadius: CGFloat = 12
    public static let sheetHeaderTop: CGFloat = 14
    public static let sheetHeaderBottom: CGFloat = 4
    public static let sheetNameTop: CGFloat = 8
    public static let sheetGap: CGFloat = 12
    public static let sheetFooterPaddingV: CGFloat = 14
    public static let pressedOpacity: Double = 0.8
    public static let fieldRadius: CGFloat = 7
    public static let fieldPaddingV: CGFloat = 9
    public static let fieldPaddingH: CGFloat = 11
    public static let buttonRadius: CGFloat = 7
    public static let buttonPaddingV: CGFloat = 5
    public static let buttonPaddingH: CGFloat = 14
    public static let focusRing: CGFloat = 3
    public static let focusRingOpacity: Double = 0.18
    public static let messageMinHeight: CGFloat = 38

    // Settings window: one card of rows (DESIGN.md «Лист», new-task-v4 `.grp` / `.r` / `.seg`)
    public static let settingsWidth: CGFloat = 520
    /// Initial settings window height; SwiftUI content resizes it.
    public static let settingsPlaceholderHeight: CGFloat = 240
    public static let settingsTopOffset: CGFloat = 80
    public static let cardRadius: CGFloat = 8
    public static let cardRowPaddingV: CGFloat = 9
    public static let cardRowPaddingH: CGFloat = 12
    public static let cardRowGap: CGFloat = 10
    /// Settings labels are longer than the new-task ones (e.g. "Terminal background").
    public static let settingsLabelWidth: CGFloat = 150
    public static let segmentRadius: CGFloat = 7
    public static let segmentPadding: CGFloat = 2
    public static let segmentItemRadius: CGFloat = 5
    public static let segmentItemPaddingV: CGFloat = 3
    public static let segmentItemPaddingH: CGFloat = 11

    // New-task sheet card (new-task-v4 `.r .lbl`, `.dimrow`, `.pick`, `.dd`)
    public static let cardLabelWidth: CGFloat = 110
    /// Branch rows without worktree.
    public static let dimmedRowOpacity: Double = 0.38
    /// git stderr shown under the card.
    public static let errorMaxLines = 6
    public static let pickRadius: CGFloat = 6
    public static let pickPaddingV: CGFloat = 3
    public static let pickPaddingH: CGFloat = 8
    public static let pickGap: CGFloat = 6
    public static let pickChevronSize: CGFloat = 9
    /// ↻ next to «обновлено …».
    public static let sheetIconButtonSize: CGFloat = 22
    // Branch picker dropdown
    public static let dropdownWidth: CGFloat = 340
    public static let dropdownRadius: CGFloat = 9
    public static let dropdownPaddingH: CGFloat = 11
    public static let dropdownSearchPaddingV: CGFloat = 8
    public static let dropdownRowHeight: CGFloat = 26
    public static let dropdownSectionHeight: CGFloat = 22
    public static let dropdownListMaxHeight: CGFloat = 260
}

/// One-shot animations only (no loops: zero work when idle); none when the user asked to reduce motion.
@MainActor enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func ease(_ duration: Double) -> Animation? { reduced ? nil : .easeInOut(duration: duration) }
}
