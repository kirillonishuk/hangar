import AgentStatus
import AppKit
import Git
import SwiftUI
import Usage

/// Colors and sizes from docs/design/DESIGN.md. UI code must use these, not literals.
public enum Theme {
    // Fonts: `Theme.Typography` (Theme+Tokens.swift).

    // Sizes
    /// Sidebar 256 (200–320), inspector 320 (280–420): design system §2.4; the defaults live in `WorkspaceState`.
    public static let sidebarMin: CGFloat = 200
    public static let sidebarMax: CGFloat = 320
    public static let windowSize = NSSize(width: 1200, height: 760)
    public static let windowMinSize = NSSize(width: 800, height: 500)
    public static let sidebarRailWidth: CGFloat = 44
    /// Right sidebar drag limits; tree level indent, file row padding (~22 high).
    public static let inspectorMin: CGFloat = 280
    public static let inspectorMax: CGFloat = 420
    public static let treeIndent: CGFloat = Space.s3
    public static let fileRowPaddingV: CGFloat = Space.s1
    public static let inspectorSegmentPaddingH: CGFloat = Space.s3
    /// Changes / Search rows show a folder only with at least this much room.
    public static let rowFolderMin: CGFloat = 48
    /// Mouse-down tolerance around a 1 pt split divider (which divider is being dragged).
    public static let dividerHitSlop: CGFloat = 4
    /// Bottom terminal drawer (bar `Height.barPane`): grab strip on its top edge, height limit, open/close animation.
    public static let drawerGrabHeight: CGFloat = 5
    public static let drawerMaxFraction: CGFloat = 0.7
    public static let drawerAnimation: Double = 0.18

    /// `waiting` halo: ring of `waiting` at 25%.
    public static let haloWidth: CGFloat = 3
    /// Rail monogram's corner dot and its `bg1` border.
    public static let railDot: CGFloat = 7
    public static let railDotBorder: CGFloat = 1.5
    /// Rail dot sticks out of the monogram's top-right corner by this much.
    public static let railDotOffset: CGFloat = 3.5
    /// A tab's status dot sits on its icon's bottom-right corner, this far out.
    public static let tabDotOffset: CGFloat = 3
    public static let rowPaddingH: CGFloat = Space.s3
    public static let tabPaddingH: CGFloat = Space.s3
    public static let tabGap: CGFloat = Space.s1
    /// Inline rename field in a tab.
    public static let tabRenameWidth: CGFloat = 140
    /// Insertion line while dragging sidebar rows (`accent`); the tab bar opens a slot instead (`tabDropSlot*`).
    public static let dropLineWidth: CGFloat = 2
    /// Pointer travel before a press becomes a drag.
    public static let dragThreshold: CGFloat = 4
    /// Dragging a tab/pane over a pane: each edge's drop zone, as a share of that side (DESIGN «Сплиты»).
    public static let paneDropZone: CGFloat = 0.25
    public static let paneDropLineWidth: CGFloat = 2
    public static let paneDragGhostHeight: CGFloat = Height.tab
    public static let paneDragGhostPaddingH: CGFloat = Space.s3
    public static let paneDragGhostMaxWidth: CGFloat = 260
    /// From the pointer to the chip's top-left corner.
    public static let paneDragGhostOffset: CGFloat = Space.s3
    public static let paneDragGhostShadowRadius: CGFloat = 10
    public static let paneDragGhostShadowOpacity: CGFloat = 0.5
    public static let tabTitleLeading: CGFloat = Space.s2
    public static let tabTitleTrailing: CGFloat = Space.s2
    /// Icons v2 (decision #56): drawn on a 16 grid with a 1.5 pt line at every size.
    public static let iconGrid: CGFloat = 16
    public static let iconStroke: CGFloat = 1.5
    /// Row markers sit on the rail's centre line in both modes (icons-sidebar.html `.g`), so the rail's icons line up with its tiles.
    public static let gutterMarkerX: CGFloat = sidebarRailWidth / 2
    public static let gutterTextX: CGFloat = gutterMarkerX + Icon.toolbar / 2 + Space.s2
    public static let sectionGap: CGFloat = Space.s2
    public static let sidebarAnimation: Double = 0.18
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
    public static let inlineGap: CGFloat = Space.iconGap
    /// Least gap between a row's text and its trailing buttons.
    public static let rowEndGap: CGFloat = Space.s2
    public static let railInset: CGFloat = Space.s1
    public static let paneHeaderPaddingH: CGFloat = Space.s3
    /// Gap between the header's «⇱» and «×».
    public static let paneHeaderButtonGap: CGFloat = Space.s1

    /// Every sheet (§3.14: new chat, project settings, remote project, server, integration, update): one width.
    public static let sheetWidth: CGFloat = 520
    /// Initial sheet height; SwiftUI content resizes the sheet.
    public static let sheetPlaceholderHeight: CGFloat = 200
    public static let sheetPaddingH: CGFloat = Space.s5
    public static let sheetHeaderTop: CGFloat = Space.s5
    public static let sheetHeaderBottom: CGFloat = Space.s1
    public static let sheetNameTop: CGFloat = Space.s2
    public static let sheetGap: CGFloat = Space.s3
    public static let sheetFooterPaddingV: CGFloat = Space.s3
    public static let fieldRadius: CGFloat = Radius.control
    public static let fieldPaddingH: CGFloat = Space.s2
    public static let buttonPaddingH: CGFloat = Space.s3
    public static let focusRing: CGFloat = Control.ringWidth
    public static let settingsTopOffset: CGFloat = 80
    public static let cardRadius: CGFloat = Radius.popover
    public static let cardRowPaddingV: CGFloat = settingsRowPaddingV
    public static let cardRowPaddingH: CGFloat = Space.s3
    /// Both sides of an `NSTextField`'s line fragment padding (2 + 2): text width inside a plain field.
    public static let fieldTextInset: CGFloat = 4
    public static let cardRowGap: CGFloat = Space.s3
    public static let segmentRadius: CGFloat = Radius.control

    // New-task sheet card (new-task-v4 `.r .lbl`, `.dimrow`, `.pick`, `.dd`)
    /// The server check's report rows: a tool's name column (a table, not a form; spec §7.1).
    public static let reportLabelWidth: CGFloat = 168
    /// git stderr shown under the card.
    public static let errorMaxLines = 6
    public static let pickPaddingV: CGFloat = Space.s1
    public static let pickGap: CGFloat = Space.iconGap
    public static let pickChevronSize: CGFloat = Icon.inline
    // SSH hosts and the server sheet
    public static let installTerminalHeight: CGFloat = 260
    public static let reportRowPaddingV: CGFloat = settingsRowPaddingV
    /// The smallest server report before it scrolls (the rest of the sheet is measured: `SheetChrome`).
    public static let serverReportMinHeight: CGFloat = 160
}

extension Theme {
    /// Subscription limits (DESIGN.md «Блок лимитов», limits.html); thresholds come from `UsageThreshold`.
    public enum Limit {
        public static var track: Color { ui.of(Theme.palette.limTrack) }
        public static var ok: Color { ui.of(Theme.palette.limOk) }
        public static var warn: Color { ui.waiting }
        public static var full: Color { ui.failed }
        public static var fullText: Color { Color(nsColor: Theme.failedText) }

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
        public static let blockBar: CGFloat = 4
        public static let barGap: CGFloat = 3
        public static let percentWidth: CGFloat = 34
        public static let rowGap: CGFloat = Space.s2
        public static let rowPaddingV: CGFloat = Space.s1
        public static let rowPaddingH: CGFloat = Space.s3
        public static let blockPaddingV: CGFloat = Space.s2
        public static let blockPaddingH: CGFloat = Space.s2
        public static let popoverWidth: CGFloat = 330
        public static let popoverPaddingV: CGFloat = Space.s3
        public static let popoverPaddingH: CGFloat = Space.s4
        public static let popoverBar: CGFloat = 6
        public static let itemGap: CGFloat = Space.s3
    }

    /// «Входящие»: the titlebar bell and its popover (look of the limits popover).
    public enum Inbox {
        /// The toolbar bell's counter (§3.13): a `failed` circle 14 high.
        public static let badge: CGFloat = 14
        public static let popoverWidth: CGFloat = 380
        public static let popoverPaddingV: CGFloat = Space.s2
        public static let popoverPaddingH: CGFloat = Space.s2
        public static let rowPaddingV: CGFloat = Space.s2
        public static let rowPaddingH: CGFloat = Space.s3
        public static let rowGap: CGFloat = Space.s2
        public static let lineGap: CGFloat = Space.s1
        public static let buttonHeight: CGFloat = Height.controlSmall
        public static let sectionPaddingTop: CGFloat = Space.s2
        /// More rows than this scroll inside `listHeight`.
        public static let scrollAfter = 7
        public static let listHeight: CGFloat = 440
        public static let emptyHeight: CGFloat = 64
        /// «Проект › сессия · время» line; the reason icon centres on it.
        public static let firstLine: CGFloat = 16

        public static let reasonIcon: CGFloat = Icon.row

        /// Blocking reasons in accent, errors red, limit in the limit colour, done muted.
        public static func reasonTint(_ reason: AttentionReason) -> Color {
            switch reason {
            case .permission, .question: ui.accentText
            case .failed: ui.failed
            case .limit: ui.status(.limit)
            case .done: ui.text3
            }
        }
    }
}

extension Theme {
    /// Diff in the integration consent sheet (DESIGN.md «Git и diff»).
    public enum Diff {
        public static var add: Color { ui.of(Theme.palette.diffAdd) }
        public static var del: Color { ui.of(Theme.palette.diffDel) }
        public static var addMarker: Color { badgeA }
        public static var delMarker: Color { badgeD }
        public static var hunk: Color { ui.accentText }
        public static var badgeM: Color { ui.gitM }
        public static var badgeA: Color { ui.gitA }
        public static var badgeD: Color { ui.gitD }
        /// Line height ≈ 1.6.
        public static let linePaddingV: CGFloat = 3
        public static let maxHeight: CGFloat = 360
        public static let markerWidth: CGFloat = 16
        public static let paddingH: CGFloat = Space.s2
        /// Diff tab: the path header and hunk headers (mockup `.dh` 6×14, gap 12; `.hunk` 2×14).
        public static let headerPaddingV: CGFloat = Space.s2
        /// The «2 из 5» slot before the previous / next change buttons.
        public static let counterWidth: CGFloat = 48
        public static let headerPaddingH: CGFloat = Space.s3
        public static let headerGap: CGFloat = Space.s3

        /// Syntax colors: muted on `bg0`, readable over the add/del tints; plain text stays `text1`.
        static func syntax(_ kind: SyntaxKind) -> Color { ui.of(Hex(syntaxHex(kind))) }

        /// Also the Monaco theme's token colors (`MonacoTheme`).
        static func syntaxHex(_ kind: SyntaxKind) -> UInt32 {
            switch kind {
            case .keyword: 0xb79bd9
            case .string: 0xa9c48f
            case .comment: 0x75819a
            case .number: 0xd5a274
            case .type: 0xdcc283
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
    public static let paletteRadius: CGFloat = Radius.window
    /// The card's top edge, as a fraction of the window height from its top.
    public static let paletteTopFraction: CGFloat = 0.16
    public static let paletteQueryPaddingV: CGFloat = Space.s3
    public static let palettePaddingH: CGFloat = Space.s5
    public static let paletteRowHeight: CGFloat = Height.rowLarge
    public static let paletteRowInset: CGFloat = Space.s2
    public static let paletteRowRadius: CGFloat = Radius.control
    public static let paletteSectionHeight: CGFloat = Height.barPane
    public static let paletteMarker: CGFloat = Space.s5
    public static let paletteGap: CGFloat = Space.s2
    public static let paletteIconGap: CGFloat = Space.s1
    /// Fixed list height: the card never changes size while typing (no jumps).
    public static let paletteListHeight: CGFloat = 384
    public static let paletteFadeIn: Double = 0.12
}

/// One-shot animations only (no loops: zero work when idle); none when the user asked to reduce motion.
@MainActor enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func ease(_ duration: Double) -> Animation? { reduced ? nil : .easeInOut(duration: duration) }
}
