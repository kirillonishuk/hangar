import AgentStatus
import AppKit
import Git
import SwiftUI
import Usage

/// Colors and sizes from docs/design/DESIGN.md. UI code must use these, not literals.
public enum Theme {
    // Fonts: `Theme.Typography` (Theme+Tokens.swift).

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
    public static let inspectorSegmentPaddingH: CGFloat = 10
    /// Changes / Search rows show a folder only with at least this much room.
    public static let rowFolderMin: CGFloat = 48
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
    /// Bottom terminal drawer: bar height, grab strip on its top edge, height limits, open/close animation.
    public static let drawerBarHeight: CGFloat = 28
    public static let drawerGrabHeight: CGFloat = 5
    public static let drawerMaxFraction: CGFloat = 0.7
    public static let drawerAnimation: Double = 0.18

    public static let statusDot: CGFloat = 8
    /// `waiting` halo: ring of `waiting` at 25%.
    public static let haloWidth: CGFloat = 3
    /// Rail monogram's corner dot and its `bg1` border.
    public static let railDot: CGFloat = 7
    public static let railDotBorder: CGFloat = 1.5
    /// Rail dot sticks out of the monogram's top-right corner by this much.
    public static let railDotOffset: CGFloat = 3.5
    /// A tab's status dot sits on its icon's bottom-right corner, this far out.
    public static let tabDotOffset: CGFloat = 3
    public static let worktreeEndIcon: CGFloat = 12
    public static let rowPaddingH: CGFloat = 14
    public static let tabPaddingV: CGFloat = 6
    public static let tabPaddingH: CGFloat = 14
    public static let tabGap: CGFloat = 2
    public static let tabRadius: CGFloat = 6
    /// Inline rename field in a tab.
    public static let tabRenameWidth: CGFloat = 140
    /// Insertion line while dragging sidebar rows (`accent`); the tab bar opens a slot instead (`tabDropSlot*`).
    public static let dropLineWidth: CGFloat = 2
    /// Pointer travel before a press becomes a drag.
    public static let dragThreshold: CGFloat = 4
    /// Dragging a tab/pane over a pane: each edge's drop zone, as a share of that side (DESIGN «Сплиты»).
    public static let paneDropZone: CGFloat = 0.25
    public static let paneDropLineWidth: CGFloat = 2
    public static let paneDragGhostHeight: CGFloat = 28
    public static let paneDragGhostPaddingH: CGFloat = 10
    public static let paneDragGhostMaxWidth: CGFloat = 260
    /// From the pointer to the chip's top-left corner.
    public static let paneDragGhostOffset: CGFloat = 12
    public static let paneDragGhostShadowRadius: CGFloat = 10
    public static let paneDragGhostShadowOpacity: CGFloat = 0.5
    public static let tabTitleLeading: CGFloat = 8
    public static let tabTitleTrailing: CGFloat = 10
    public static let railRowHeight: CGFloat = 32
    /// Icons v2 (decision #56): drawn on a 16 grid with a 1.5 pt line at every size.
    public static let iconSize: CGFloat = 16
    public static let iconGrid: CGFloat = 16
    public static let iconStroke: CGFloat = 1.5
    public static let iconGap: CGFloat = 6
    public static let smallIconSize: CGFloat = 10
    /// Row markers sit on the rail's centre line in both modes (icons-sidebar.html `.g`), so the rail's icons line up with its tiles.
    public static let gutterMarkerX: CGFloat = sidebarRailWidth / 2
    public static let gutterTextX: CGFloat = 34
    public static let sectionGap: CGFloat = 10
    public static let footerRowHeight: CGFloat = 28
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
    public static let inlineGap: CGFloat = 6
    /// Least gap between a row's text and its trailing buttons.
    public static let rowEndGap: CGFloat = 8
    public static let projectTileRadius: CGFloat = 6
    public static let railItemRadius: CGFloat = 6
    public static let railInset: CGFloat = 4
    public static let paneHeaderPaddingH: CGFloat = 12
    /// A split pane's header strip: constant, so the terminal never jumps when its buttons show.
    public static let paneHeaderHeight: CGFloat = 24
    public static let paneHeaderIcon: CGFloat = 12
    /// Gap between the header's «⇱» and «×».
    public static let paneHeaderButtonGap: CGFloat = 2

    /// Every sheet (new session, project settings, remote project, server, integration): one width, one card width.
    public static let sheetWidth: CGFloat = 620
    /// Initial sheet height; SwiftUI content resizes the sheet.
    public static let sheetPlaceholderHeight: CGFloat = 200
    public static let sheetPaddingH: CGFloat = 18
    public static let sheetRadius: CGFloat = 12
    public static let sheetHeaderTop: CGFloat = 14
    public static let sheetHeaderBottom: CGFloat = 4
    public static let sheetNameTop: CGFloat = 8
    public static let sheetGap: CGFloat = 12
    public static let sheetFooterPaddingV: CGFloat = 14
    public static let fieldRadius: CGFloat = 7
    public static let fieldPaddingH: CGFloat = 11
    public static let buttonPaddingH: CGFloat = 14
    public static let focusRing: CGFloat = 3
    public static let settingsTopOffset: CGFloat = 80
    public static let cardRadius: CGFloat = 8
    public static let cardRowPaddingV: CGFloat = 9
    public static let cardRowPaddingH: CGFloat = 12
    /// Both sides of an `NSTextField`'s line fragment padding (2 + 2): text width inside a plain field.
    public static let fieldTextInset: CGFloat = 4
    public static let cardRowGap: CGFloat = 10
    public static let segmentRadius: CGFloat = 7

    // New-task sheet card (new-task-v4 `.r .lbl`, `.dimrow`, `.pick`, `.dd`)
    /// One label column in every sheet: «Команда после создания» (~165 at `sheetRow`, ru) on one line.
    public static let cardLabelWidth: CGFloat = 168
    /// git stderr shown under the card.
    public static let errorMaxLines = 6
    public static let pickPaddingV: CGFloat = 3
    public static let pickGap: CGFloat = 6
    public static let pickChevronSize: CGFloat = 10
    /// ↻ next to «обновлено …».
    public static let sheetIconButtonSize: CGFloat = 22
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
        public static let badgePaddingH: CGFloat = 7
        public static let badgePaddingV: CGFloat = 1
    }

    /// «Входящие»: the titlebar bell and its popover (look of the limits popover).
    public enum Inbox {
        /// Reserved for up to «99+» right of the bell, so the bell never moves.
        public static let countWidth: CGFloat = 22
        public static let bellGap: CGFloat = 2
        public static let bellPaddingH: CGFloat = 6
        public static let popoverWidth: CGFloat = 380
        public static let popoverPaddingV: CGFloat = 8
        public static let popoverPaddingH: CGFloat = 8
        public static let rowPaddingV: CGFloat = 6
        public static let rowPaddingH: CGFloat = 8
        public static let rowGap: CGFloat = 8
        public static let lineGap: CGFloat = 3
        public static let buttonHeight: CGFloat = 22
        public static let sectionPaddingTop: CGFloat = 8
        /// More rows than this scroll inside `listHeight`.
        public static let scrollAfter = 7
        public static let listHeight: CGFloat = 440
        public static let emptyHeight: CGFloat = 64
        /// «Проект › сессия · время» line; the reason icon centres on it.
        public static let firstLine: CGFloat = 16

        public static let reasonIcon: CGFloat = 14

        /// Blocking reasons in accent, errors red, limit in the limit colour, done muted.
        public static func reasonTint(_ reason: AttentionReason) -> Color {
            switch reason {
            case .permission, .question: ui.accentText
            case .failed: ui.failed
            case .limit: ui.status(.limit)
            case .done: ui.text3
            }
        }

        static func tint(_ tint: BellTint) -> Color {
            switch tint {
            case .accent: ui.accentText
            case .failed: ui.failed
            case .muted: ui.text2
            }
        }
    }
}

extension Theme {
    /// Diff in the integration consent sheet (DESIGN.md «Git и diff»).
    public enum Diff {
        private static func c(_ hex: UInt32, _ opacity: Double = 1) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
        }
        public static var add: Color { ui.of(Theme.palette.diffAdd) }
        public static var del: Color { ui.of(Theme.palette.diffDel) }
        public static var addMarker: Color { badgeA }
        public static var delMarker: Color { badgeD }
        public static var hunk: Color { ui.accentText }
        public static var badgeM: Color { ui.of(Theme.palette.gitM) }
        public static var badgeA: Color { ui.of(Theme.palette.gitA) }
        public static var badgeD: Color { ui.of(Theme.palette.gitD) }
        /// Line number column.
        public static let gutter: CGFloat = 34
        /// Line height ≈ 1.6.
        public static let linePaddingV: CGFloat = 3
        public static let maxHeight: CGFloat = 360
        public static let markerWidth: CGFloat = 16
        public static let paddingH: CGFloat = 8
        /// Diff tab: the path header and hunk headers (mockup `.dh` 6×14, gap 12; `.hunk` 2×14).
        public static let headerPaddingV: CGFloat = 6
        /// Header's previous / next change buttons.
        public static let navButtonWidth: CGFloat = 24
        public static let counterWidth: CGFloat = 48
        public static let navButtonHeight: CGFloat = 22
        public static let navButtonRadius: CGFloat = 5
        public static let headerPaddingH: CGFloat = 14
        public static let headerGap: CGFloat = 12
        public static let hunkPaddingV: CGFloat = 2

        /// Syntax colors: muted on `bg0`, readable over the add/del tints; plain text stays `text1`.
        static func syntax(_ kind: SyntaxKind) -> Color { c(syntaxHex(kind)) }

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
    public static let paletteRadius: CGFloat = 12
    /// The card's top edge, as a fraction of the window height from its top.
    public static let paletteTopFraction: CGFloat = 0.16
    public static let paletteQueryPaddingV: CGFloat = 14
    public static let palettePaddingH: CGFloat = 18
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
