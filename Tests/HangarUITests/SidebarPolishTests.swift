import SwiftUI
import Testing
@testable import HangarUI

@Suite struct SidebarPolishTests {
    @Test func hoverFillOnlyOnActionableRows() {
        let p = HoverPalette.focus
        #expect(p.fill(selected: false, pressed: false, hover: true, interactive: true) == Theme.ui.hover)
        #expect(p.fill(selected: false, pressed: true, hover: true, interactive: true) == Theme.ui.hover2)
        // Section headers and other rows without an action: no hover/press fill.
        #expect(p.fill(selected: false, pressed: false, hover: true, interactive: false) == .clear)
        #expect(p.fill(selected: false, pressed: true, hover: true, interactive: false) == .clear)
        #expect(p.fill(selected: true, pressed: false, hover: false, interactive: true) == Theme.ui.selectedFocus)
        #expect(HoverPalette.standard.fill(selected: true, pressed: false, hover: false, interactive: true) == Theme.ui.selected)
        #expect(HoverPalette.standard.fill(selected: false, pressed: false, hover: true, interactive: true) == Theme.ui.hover)
    }

    /// The trailing-actions fade matches what the row shows underneath.
    @Test func rowBackgroundUnderOverlay() {
        let p = HoverPalette.focus
        #expect(p.background(selected: false, hover: false, base: Theme.ui.bg1) == Theme.ui.bg1)
        #expect(p.background(selected: false, hover: true, base: Theme.ui.bg1) == Theme.ui.hover)
        #expect(p.background(selected: true, hover: true, base: Theme.ui.bg1) == Theme.ui.selectedFocus)
    }

    @Test func sidebarHoverIsLighterThanSidebar() {
        func luminance(_ c: NSColor) -> CGFloat { c.redComponent + c.greenComponent + c.blueComponent }
        #expect(luminance(Theme.hover) > luminance(Theme.bg1))
        #expect(luminance(Theme.hover) < luminance(Theme.selected))
        #expect(luminance(Theme.hover2) > luminance(Theme.hover))
    }

    @Test func railTileStyleFollowsSelection() {
        #expect(RailTileStyle(selected: false) == RailTileStyle(fill: Theme.ui.hover, border: Theme.ui.line2, text: Theme.ui.text1))
        #expect(RailTileStyle(selected: true) == RailTileStyle(fill: Theme.ui.railTileSelected, border: Theme.ui.railTileSelectedBorder, text: Theme.ui.text0))
    }

    /// Brand logos are embedded path data: they exist without any bundle and are not a symbol fallback.
    @Test @MainActor func brandLogosDoNotNeedBundle() {
        for icon in [Icon.claude, Icon.codex] {
            #expect(icon.isBrand)
            let image = icon.image
            #expect(!image.isTemplate)
            #expect(image.size == NSSize(width: Theme.Icon.toolbar, height: Theme.Icon.toolbar))
            #expect(BrandLogo.path(icon == .claude ? BrandLogo.claude : BrandLogo.openai).bounds.width > 20)
        }
        #expect(!Icon.shell.isBrand)
    }

    /// Design system §2.2: four UI sizes plus mono, nothing below `caption` 11.
    @Test func fontsAtOrAboveFloor() {
        let T = Theme.Typography.self
        #expect([T.title, T.body, T.secondary, T.caption].map(\.size) == [15, 13, 12, 11])
        #expect([T.mono, T.monoSmall].allSatisfy { $0.mono && $0.size >= T.caption.size })
    }
}
