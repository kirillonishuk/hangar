import AppKit
import SwiftUI

/// Settings → Appearance → Editor (#108, #109, editor-theme.html): the app theme tiles, the color list with its preview,
/// the color popover. Sized for the settings window's minimum (680 pt: a 441 pt page), the preview above the list.
extension Theme {
    enum EditorSettings {
        // App theme tiles (#109): a mini window — title bar, sidebar, code in the editor theme the app theme carries.
        // Three in a row at the minimum page width (441 pt): ≈ 139 each, ≈ 95 of code after the sidebar strip.
        static let tileHeight: CGFloat = 92
        static let tileTitlebar: CGFloat = 10
        static let tileSidebarBar: CGFloat = 3
        static let tileSidebarShort: CGFloat = 10
        static let tileSidebarGap: CGFloat = 6
        static let tileSidebarPadding: CGFloat = 5
        static let tileFont: CGFloat = 9
        static let tileLineHeight: CGFloat = 12
        static let tileCodePadding: CGFloat = 7
        static let tileCodePaddingV: CGFloat = 6
        /// Room above «Редактор», the page's second heading: it starts a part of its own.
        static let subsectionGap: CGFloat = 4
        /// The editor theme's hint keeps two lines of room: switching doesn't move the page.
        static let hintLines = 2

        /// Preview beside the list from this page width (the 970 pt default window: 731), stacked above it below.
        static let besidePageWidth: CGFloat = 712
        static let besidePreviewWidth: CGFloat = 400
        static let besideGap: CGFloat = 12

        // Preview: an editor-like box, as tall as its longest sample (no jump between TypeScript / JSON / Diff).
        static let previewFont: CGFloat = 12
        static let previewLineHeight: CGFloat = 18
        static let previewLines = 12
        /// At the window's minimum the preview shows 6 lines; the page keeps `previewReserve` for the rest.
        static let previewMinLines = 6
        static let previewReserve: CGFloat = 300
        static let previewPaddingV: CGFloat = 8
        static let previewPaddingH: CGFloat = 10
        static let previewGutter: CGFloat = 26
        static let previewDiffGutter: CGFloat = 22
        static let previewDiffMarker: CGFloat = 16
        static let previewCodeGap: CGFloat = 14
        static let cursorWidth: CGFloat = 2
        static let guideWidth: CGFloat = 1
        static let outlineWidth: CGFloat = 1.5
        static let outlineRadius: CGFloat = 3
        /// Everything but the hovered row's tokens.
        static let dimOpacity: Double = 0.25
        static let headerHeight: CGFloat = 34

        // Color list
        static let rowHeight: CGFloat = 28
        static let swatch: CGFloat = 14
        static let swatchRadius: CGFloat = 3
        static let swatchGap: CGFloat = 4
        static let modifiedDot: CGFloat = 5
        static let dotSlot: CGFloat = 10
        static let groupHeight: CGFloat = 30

        // Color popover (NSPopover)
        static let popoverWidth: CGFloat = 284
        static let popoverPadding: CGFloat = 12
        static let popoverGap: CGFloat = 10
        static let popoverSwatch: CGFloat = 30
        static let barHeight: CGFloat = 12
        static let knob: CGFloat = 16
        static let knobBorder: CGFloat = 2
        static let gridSwatch: CGFloat = 20
        static let gridGap: CGFloat = 5
        static let gridColumns = 9
        static let hexFieldWidth: CGFloat = 96
        static let alphaFieldWidth: CGFloat = 52
        /// Translucent colors over a checkerboard.
        static let checker: CGFloat = 4

        // Options
        static let stepperValueWidth: CGFloat = 92
        static let fontMenuWidth: CGFloat = 190
    }
}

extension Theme.ui {
    /// An editor theme's color (`#rrggbb(aa)`): data chosen by the user, not a theme token.
    static func editor(_ hex: String) -> Color {
        guard let c = EditorHex.components(hex) else { return .clear }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
