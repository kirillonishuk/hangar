import AgentStatus
import AppKit
import Git
import SwiftUI
import Usage

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
    public static let hoverStrong = ns(0x2b3444)  // "+ New Session" button
    public static let pressed = ns(0x192030)
    /// Sidebar (and popovers on `sheet`): hover lighter than `sidebar`, pressed darker (DESIGN.md «Состояния»).
    public static let sidebarHover = ns(0x283246)
    public static let sidebarPressed = ns(0x1b2333)
    /// Rail task monogram tile (icons-sidebar.html `.mono`), selected variant on a `selection` row.
    public static let railTile = ns(0x283246)
    public static let railTileBorder = ns(0x343f55)
    public static let railTileSelected = ns(0x34466a)
    public static let railTileSelectedBorder = ns(0x46598a)
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
        public static let sidebarHover = Color(nsColor: Theme.sidebarHover)
        public static let sidebarPressed = Color(nsColor: Theme.sidebarPressed)
        public static let railTile = Color(nsColor: Theme.railTile)
        public static let railTileBorder = Color(nsColor: Theme.railTileBorder)
        public static let railTileSelected = Color(nsColor: Theme.railTileSelected)
        public static let railTileSelectedBorder = Color(nsColor: Theme.railTileSelectedBorder)
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
        public static let segment: CGFloat = 12
        /// The floor: nothing smaller except limit badges (11).
        public static let small: CGFloat = 11.5
        public static let counter: CGFloat = 11.5
        // Sidebar, as in Pane: section headers, rows, bottom buttons.
        public static let section: CGFloat = 11.5
        public static let sidebarRow: CGFloat = 13.5
        public static let sidebarFooter: CGFloat = 13
        public static let projectTracking: CGFloat = 0.06  // em
    }

    // Sizes
    public static let sidebarWidth: CGFloat = 240
    public static let sidebarMin: CGFloat = 200
    public static let sidebarMax: CGFloat = 320
    public static let tabBarHeight: CGFloat = 34
    /// One titlebar across the whole window (redesign v1 §6).
    public static let titleBarHeight: CGFloat = 38
    /// Hit area of titlebar buttons (sidebar toggles), radius `railItemRadius`.
    public static let titleButtonSize: CGFloat = 28
    /// x of the left sidebar toggle: clear of the traffic lights (x 9…69); the same collapsed and expanded.
    public static let titlebarToggleX: CGFloat = 84
    /// Same toggle in full screen, where the traffic lights are hidden.
    public static let titlebarFullScreenX: CGFloat = 12
    public static let titlebarTrailing: CGFloat = 10
    public static let titleBranchIcon: CGFloat = 12
    /// Gap between the titlebar and «+ Новая сессия».
    public static let sidebarTopGap: CGFloat = 8
    public static let windowSize = NSSize(width: 1200, height: 760)
    public static let windowMinSize = NSSize(width: 800, height: 500)
    public static let sidebarRailWidth: CGFloat = 44
    /// Right sidebar (DESIGN.md «Раскладка»): default width, drag limits; tree level indent, file row padding (~22 high).
    public static let inspectorWidth: CGFloat = 340
    public static let inspectorMin: CGFloat = 300
    public static let inspectorMax: CGFloat = 420
    public static let treeIndent: CGFloat = 12
    public static let fileRowPaddingV: CGFloat = 3
    public static let inspectorSegmentRadius: CGFloat = 6
    public static let inspectorSegmentItemRadius: CGFloat = 4
    public static let inspectorSegmentPaddingH: CGFloat = 10
    /// Changes hint under the list: gap above, line spacing.
    public static let changesHintTop: CGFloat = 10
    public static let changesHintLineGap: CGFloat = 2
    /// Mouse-down tolerance around a 1 pt split divider (which divider is being dragged).
    public static let dividerHitSlop: CGFloat = 4
    /// Window status bar (redesign v1 §7): height, side padding, gap between parts; clickable items 20 high, radius 4.
    /// Also the height of a leaf's «↩ перезапустить» bar.
    public static let statusBarHeight: CGFloat = 24
    public static let statusBarPaddingH: CGFloat = 12
    public static let statusBarGap: CGFloat = 12
    public static let statusItemHeight: CGFloat = 20
    public static let statusItemPaddingH: CGFloat = 4
    public static let statusItemRadius: CGFloat = 4
    public static let statusRingWidth: CGFloat = 1.5
    /// Bottom terminal drawer: bar height, grab strip on its top edge, height limits, open/close animation.
    public static let drawerBarHeight: CGFloat = 28
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
    /// Rail dot sticks out of the monogram's top-right corner by this much.
    public static let railDotOffset: CGFloat = 3.5
    public static let worktreeEndIcon: CGFloat = 12
    public static let rowPaddingH: CGFloat = 14
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
    public static let tabTitleLeading: CGFloat = 8
    public static let tabTitleTrailing: CGFloat = 10
    public static let railRowHeight: CGFloat = 32
    /// Icons v2 (decision #56): drawn on a 16 grid with a 1.5 pt line at every size.
    public static let iconSize: CGFloat = 16
    public static let iconGrid: CGFloat = 16
    public static let iconStroke: CGFloat = 1.5
    public static let iconGap: CGFloat = 6
    public static let smallIconSize: CGFloat = 10
    public static let gutterMarkerX: CGFloat = 20
    public static let gutterTextX: CGFloat = 32
    public static let sectionGap: CGFloat = 10
    public static let footerRowHeight: CGFloat = 28
    public static let sidebarAnimation: Double = 0.18
    public static let hoverFade: Double = 0.12
    public static let selectionFade: Double = 0.15
    public static let pulseDuration: Double = 0.4
    public static let pulseScale: CGFloat = 1.6
    public static let projectTileSize: CGFloat = 24
    /// Rail task monogram tile, centred in the rail.
    public static let railTileSize: CGFloat = 22
    public static let railTileBorderWidth: CGFloat = 1
    /// Rail section header: a short `line` separator in a 12 pt row (icons-sidebar.html `.rail .hd`).
    public static let railHeaderHeight: CGFloat = 12
    public static let railHeaderLine: CGFloat = 24
    public static let railHeaderLineWidth: CGFloat = 1
    /// Gap between inline parts of a row (name · project, icon · host).
    public static let inlineGap: CGFloat = 6
    /// Least gap between a row's text and its trailing buttons.
    public static let rowEndGap: CGFloat = 8
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
    /// As wide as the sheets: the integration rows carry a sentence and a button.
    public static let settingsWidth: CGFloat = 580
    /// Initial settings window height; SwiftUI content resizes it.
    public static let settingsPlaceholderHeight: CGFloat = 240
    public static let settingsTopOffset: CGFloat = 80
    public static let cardRadius: CGFloat = 8
    public static let cardRowPaddingV: CGFloat = 9
    public static let cardRowPaddingH: CGFloat = 12
    /// Both sides of an `NSTextField`'s line fragment padding (2 + 2): text width inside a plain field.
    public static let fieldTextInset: CGFloat = 4
    public static let cardRowGap: CGFloat = 10
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
    public static let pickChevronSize: CGFloat = 10
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
    // SSH hosts and the server sheet
    public static let hostIconSize: CGFloat = 13
    /// «Claude Code на сервере»: wider than the card's usual 110, so the label stays on one line.
    public static let remoteIntegrationLabelWidth: CGFloat = 200
    public static let installTerminalHeight: CGFloat = 260
    public static let reportRowPaddingV: CGFloat = 6
    /// Heights of the sheets' other parts (title, host card, footer, margins) and the smallest report before it scrolls.
    public static let remoteSheetChrome: CGFloat = 250
    public static let serverSheetChrome: CGFloat = 140
    public static let serverReportMinHeight: CGFloat = 160
}

extension Theme {
    /// Subscription limits (DESIGN.md «Блок лимитов», limits.html); thresholds come from `UsageThreshold`.
    public enum Limit {
        private static func c(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
        }
        public static let track = c(0x30333b)
        public static let ok = c(0x5b8def)
        public static let warn = c(0xffb340)
        public static let full = c(0xff453a)
        public static let fullText = c(0xff6b61)
        public static let badgeOpacity = 0.15

        public static func color(_ level: UsageLevel) -> Color {
            switch level {
            case .ok: ok
            case .warn: warn
            case .full: full
            }
        }
        public static func color(forPercent percent: Double, limitReached: Bool) -> Color {
            color(level(percent: percent, limitReached: limitReached))
        }
        /// Percent and badge text: `ok` stays neutral.
        public static func textColor(_ level: UsageLevel) -> Color {
            switch level {
            case .ok: ui.text2
            case .warn: warn
            case .full: fullText
            }
        }

        public static let nameWidth: CGFloat = 50
        public static let nameFont: CGFloat = 11.5
        public static let blockBar: CGFloat = 4
        public static let barGap: CGFloat = 3
        public static let percentFont: CGFloat = 11.5
        public static let percentWidth: CGFloat = 34
        public static let rowGap: CGFloat = 8
        public static let rowPaddingV: CGFloat = 5
        public static let rowPaddingH: CGFloat = 6
        public static let blockPaddingV: CGFloat = 8
        public static let blockPaddingH: CGFloat = 10
        public static let popoverWidth: CGFloat = 330
        public static let popoverPaddingV: CGFloat = 14
        public static let popoverPaddingH: CGFloat = 16
        public static let popoverBar: CGFloat = 6
        public static let itemGap: CGFloat = 12
        public static let agentFont: CGFloat = 13
        public static let badgeFont: CGFloat = 11
        public static let badgePaddingH: CGFloat = 7
        public static let badgePaddingV: CGFloat = 1
    }
}

extension Theme {
    /// Diff in the integration consent sheet (DESIGN.md «Git и diff»).
    public enum Diff {
        private static func c(_ hex: UInt32, _ opacity: Double = 1) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
        }
        public static let add = c(0x98c379, 0.12)
        public static let del = c(0xe06c75, 0.12)
        public static let addMarker = c(0x98c379)
        public static let delMarker = c(0xe06c75)
        public static let hunk = c(0x56b6c2)
        public static let hunkBg = c(0x56b6c2, 0.07)
        public static let badgeM = c(0xe5c07b)
        public static let badgeA = c(0x98c379)
        public static let badgeD = c(0xe06c75)
        /// Diff view text (mono); the integration sheet keeps its smaller `sheetFont`.
        public static let font: CGFloat = 12.5
        public static let sheetFont: CGFloat = 11.5
        /// Line number column.
        public static let gutter: CGFloat = 34
        /// Line height ≈ 1.6.
        public static let linePaddingV: CGFloat = 3
        public static let maxHeight: CGFloat = 360
        public static let markerWidth: CGFloat = 16
        public static let paddingH: CGFloat = 8
        /// Diff tab: the path header and hunk headers (mockup `.dh` 6×14, gap 12; `.hunk` 2×14).
        public static let headerPaddingV: CGFloat = 6
        public static let headerPaddingH: CGFloat = 14
        public static let headerGap: CGFloat = 12
        public static let hunkPaddingV: CGFloat = 2
        /// The clicked line: `selection` over its add/del background.
        public static let selectedOpacity: Double = 0.7

        /// Syntax colors: muted on `bg`, readable over the add/del tints; plain text stays `text`.
        static func syntax(_ kind: SyntaxKind) -> Color {
            switch kind {
            case .keyword: c(0xb79bd9)
            case .string: c(0xa9c48f)
            case .comment: c(0x75819a)
            case .number: c(0xd5a274)
            case .type: c(0xdcc283)
            }
        }

        /// `?` as added, `R` as modified, `U` as deleted.
        public static func badge(_ c: FileChange) -> Color {
            switch c {
            case .modified, .renamed: badgeM
            case .added, .untracked: badgeA
            case .deleted, .conflicted: badgeD
            }
        }
    }
}

extension Theme {
    // ⌘P / ⇧⌘P palette (VS Code bindings, Pane/Raycast look: one floating card over the window)
    public static let paletteWidth: CGFloat = 580
    public static let paletteRadius: CGFloat = 12
    /// The card's top edge, as a fraction of the window height from its top.
    public static let paletteTopFraction: CGFloat = 0.16
    public static let paletteQueryFont: CGFloat = 17
    public static let paletteQueryPaddingV: CGFloat = 14
    public static let palettePaddingH: CGFloat = 18
    public static let paletteRowFont: CGFloat = 14
    public static let paletteDetailFont: CGFloat = 12.5
    public static let paletteRowHeight: CGFloat = 36
    public static let paletteRowInset: CGFloat = 6
    public static let paletteRowRadius: CGFloat = 7
    public static let paletteSectionHeight: CGFloat = 28
    public static let paletteMarker: CGFloat = 20
    public static let paletteGap: CGFloat = 10
    public static let paletteIconGap: CGFloat = 4
    /// Fixed list height: the card never changes size while typing (no jumps).
    public static let paletteListHeight: CGFloat = 384
    public static let paletteFadeIn: Double = 0.12
}

/// One-shot animations only (no loops: zero work when idle); none when the user asked to reduce motion.
@MainActor enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func ease(_ duration: Double) -> Animation? { reduced ? nil : .easeInOut(duration: duration) }
}
