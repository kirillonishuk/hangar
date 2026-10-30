import AppKit
import SwiftUI

/// Size tokens of the design system (docs/superpowers/specs/2026-10-30-design-system.md §2.1–2.5). They don't depend
/// on the theme; every new size takes one of these. Older `Theme` constants move onto them stage by stage (§7, §8).
extension Theme {
    /// §2.1: the 4 pt grid (`space.1` … `space.8`); nothing else.
    public enum Space {
        public static let s1: CGFloat = 4
        public static let s2: CGFloat = 8
        public static let s3: CGFloat = 12
        public static let s4: CGFloat = 16
        public static let s5: CGFloat = 20
        public static let s6: CGFloat = 24
        public static let s8: CGFloat = 32
        /// The only exception: icon ↔ text, for the optics of the glyphs.
        public static let iconGap: CGFloat = 6
    }

    /// One step of the type scale: point size and line height; SF Pro, or SF Mono for `mono`.
    public struct TypeStyle: Sendable, Equatable {
        public let size: CGFloat
        public let lineHeight: CGFloat
        public let mono: Bool

        public func font(_ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: mono ? .monospaced : .default)
        }

        public func nsFont(_ weight: NSFont.Weight = .regular) -> NSFont {
            mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        }
    }

    /// §2.2 (`type.*`): weights are only 400 and 600. Named `Typography` because `Theme.Type` is Swift's metatype.
    public enum Typography {
        public static let title = TypeStyle(size: 15, lineHeight: 20, mono: false)
        public static let body = TypeStyle(size: 13, lineHeight: 18, mono: false)
        public static let secondary = TypeStyle(size: 12, lineHeight: 16, mono: false)
        public static let caption = TypeStyle(size: 11, lineHeight: 14, mono: false)
        public static let mono = TypeStyle(size: 12, lineHeight: 16, mono: true)
        /// `mono` next to `caption` (branches in rows, `+N −M`).
        public static let monoSmall = TypeStyle(size: 11, lineHeight: 14, mono: true)
    }

    /// §2.3 (`radius.*`).
    public enum Radius {
        /// Buttons, fields, chips, segments, tabs, rows, badges.
        public static let control: CGFloat = 6
        /// The item inside a segment: track radius − padding 2 + 1.
        public static let segmentItem: CGFloat = 5
        /// Popovers, menus, cards, toasts, sheet options.
        public static let popover: CGFloat = 10
        /// Sheets, windows.
        public static let window: CGFloat = 12
    }

    /// §2.4: `control.*`, `row.*`, `bar.*`, `card.row`.
    public enum Height {
        /// Buttons and fields in sheets and settings, toolbar buttons, the toolbar branch button.
        public static let controlRegular: CGFloat = 28
        /// Buttons in rows, toasts and headers; segments, chips, pane header buttons.
        public static let controlSmall: CGFloat = 22
        public static let rowSidebar: CGFloat = 28
        /// File tree, Changes, Search, Git, menus and popovers.
        public static let rowList: CGFloat = 24
        /// History, «Продолжить».
        public static let rowLarge: CGFloat = 32
        public static let barToolbar: CGFloat = 52
        public static let barTabs: CGFloat = 36
        /// A tab inside `barTabs`.
        public static let tab: CGFloat = 26
        /// Split / editor pane header, the «Терминал» drawer, section headers.
        public static let barPane: CGFloat = 28
        /// Minimum settings card row: `controlRegular` + 6 / 6.
        public static let cardRow: CGFloat = 40
    }

    /// §2.5 (`icon.*`) and status dots.
    public enum Icon {
        /// Toolbar, sidebar footer, projects, servers.
        public static let toolbar: CGFloat = 16
        /// Tabs, files, menus, popovers.
        public static let row: CGFloat = 14
        /// Chevrons, the branch in a field, the pane header icon.
        public static let inline: CGFloat = 12
        public static let statusDot: CGFloat = 8
        public static let tabDot: CGFloat = 6
    }

    /// §2.7: the only four opacities of colours.
    public enum Opacity {
        /// Inactive (disabled) elements.
        public static let inactive: CGFloat = 0.4
        /// A role colour as a fill: badges, chips, pills, the destructive hover.
        public static let fill: CGFloat = 0.15
        /// The focus ring.
        public static let ring: CGFloat = 0.25
        /// The dimming under a sheet or a drop.
        public static let scrim: CGFloat = 0.35
    }
}
