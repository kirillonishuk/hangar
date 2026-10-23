import SwiftUI
import Testing
@testable import HangarUI

@Suite struct SidebarPolishTests {
    @Test func hoverFillOnlyOnActionableRows() {
        let p = HoverPalette.sidebar
        #expect(p.fill(selected: false, pressed: false, hover: true, interactive: true) == Theme.ui.sidebarHover)
        #expect(p.fill(selected: false, pressed: true, hover: true, interactive: true) == Theme.ui.sidebarPressed)
        // Section headers and other rows without an action: no hover/press fill.
        #expect(p.fill(selected: false, pressed: false, hover: true, interactive: false) == .clear)
        #expect(p.fill(selected: false, pressed: true, hover: true, interactive: false) == .clear)
        #expect(p.fill(selected: true, pressed: false, hover: false, interactive: true) == Theme.ui.selection)
        #expect(HoverPalette.standard.fill(selected: false, pressed: false, hover: true, interactive: true) == Theme.ui.hover)
    }

    /// The trailing-actions fade matches what the row shows underneath.
    @Test func rowBackgroundUnderOverlay() {
        let p = HoverPalette.sidebar
        #expect(p.background(selected: false, hover: false, base: Theme.ui.sidebar) == Theme.ui.sidebar)
        #expect(p.background(selected: false, hover: true, base: Theme.ui.sidebar) == Theme.ui.sidebarHover)
        #expect(p.background(selected: true, hover: true, base: Theme.ui.sidebar) == Theme.ui.selection)
    }

    @Test func sidebarHoverIsLighterThanSidebar() {
        func luminance(_ c: NSColor) -> CGFloat { c.redComponent + c.greenComponent + c.blueComponent }
        #expect(luminance(Theme.sidebarHover) > luminance(Theme.sidebar))
        #expect(luminance(Theme.sidebarHover) < luminance(Theme.selection))
        #expect(luminance(Theme.sidebarPressed) < luminance(Theme.sidebar))
    }

    @Test func railTileStyleFollowsSelection() {
        #expect(RailTileStyle(selected: false) == RailTileStyle(fill: Theme.ui.railTile, border: Theme.ui.railTileBorder, text: Theme.ui.textRow))
        #expect(RailTileStyle(selected: true) == RailTileStyle(fill: Theme.ui.railTileSelected, border: Theme.ui.railTileSelectedBorder, text: Theme.ui.selectionText))
    }

    /// Tests run without the app bundle: no logo SVGs, so the SF Symbol fallback must stay a template (tinted), not `.original` black.
    @Test @MainActor func brandFallsBackToTemplateWithoutLogo() {
        #expect(!Icon.claude.isBrand)
        #expect(!Icon.codex.isBrand)
        #expect(!Icon.shell.isBrand)
    }

    /// DESIGN.md «Типографика»: nothing below 11.5 (badges 11).
    @Test func fontsAtOrAboveFloor() {
        #expect(Theme.fontSize.small >= 11.5)
        #expect(Theme.Limit.nameFont >= 11.5)
        #expect(Theme.Limit.percentFont >= 11.5)
        #expect(Theme.Limit.badgeFont >= 11)
    }
}
