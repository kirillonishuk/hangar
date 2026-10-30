import AppKit
import Foundation
import GhosttyBridge
import Observation
import SwiftUI
import Testing
import Workspace
@testable import HangarUI

/// App themes: every theme fills every colour role (design-system spec §2.7) at the contrast the spec asks for; the
/// size tokens keep their rules; live switching.
@MainActor @Suite(.serialized) struct ThemePaletteTests {
    /// Editor chrome, git graph rails and the Claude logo: stored next to the roles, not roles themselves.
    private static let nonRoles: Set = ["edGutter", "edGutterActive", "edLine", "edSel", "edIndent", "lane1", "lane2", "lane3", "claude"]

    /// Every theme fills every role: opaque except the diff tints, 16 ANSI colours; every stored colour is a role or
    /// one of `nonRoles`, so a new colour can't bypass the role list.
    @Test(arguments: AppTheme.allCases) func paletteFillsEveryRole(_ theme: AppTheme) {
        let p = ThemePalette.of(theme)
        #expect(p.roles.map(\.key) == ThemePalette.roleNames)
        #expect(ThemePalette.roleNames.count == Set(ThemePalette.roleNames).count)
        for (name, hex) in p.roles where !name.hasPrefix("diff") { #expect(hex.alpha == 1, "\(theme.rawValue).\(name)") }
        let stored = Mirror(reflecting: p).children.compactMap { $0.value is Hex ? $0.label : nil }
        #expect(Set(stored) == Set(ThemePalette.roleNames).union(Self.nonRoles))
        #expect(p.ansi.count == 16)
    }

    /// The contrast the design system requires (spec §2.7), plus `failedText` on the chrome and popovers.
    @Test(arguments: AppTheme.allCases) func rolesMeetSpecContrast(_ theme: AppTheme) {
        let p = ThemePalette.of(theme)
        func need(_ fg: Hex, on bg: Hex, _ ratio: Double, _ what: String) {
            #expect(contrastRatio(fg.rgb, bg.rgb) >= ratio, "\(theme.rawValue) \(what): \(fg.css) on \(bg.css)")
        }
        for (t, tn) in [(p.text1, "text1"), (p.text2, "text2")] {
            for (s, sn) in [(p.bg0, "bg0"), (p.bg1, "bg1"), (p.bg2, "bg2"), (p.selected, "selected")] { need(t, on: s, 4.5, "\(tn)/\(sn)") }
        }
        need(p.onAccent, on: p.selectedFocus, 4.5, "onAccent/selectedFocus")
        need(p.onAccent, on: p.accent, 4.5, "onAccent/accent")
        need(p.text3, on: p.bg1, 3, "text3/bg1")
        need(p.text3, on: p.bg2, 3, "text3/bg2")
        for s in [p.bg1, p.bg2] { need(p.failedText, on: s, 4.5, "failedText") }
    }

    /// §2.7's construction: `hover2` = `selected`; `bg1` one step above `bg0`, `bg2` one more; hover reads on `bg0`/`bg1`.
    @Test(arguments: AppTheme.allCases) func rolesFollowTheConstruction(_ theme: AppTheme) {
        let p = ThemePalette.of(theme)
        func lum(_ h: Hex) -> Double { contrastRatio(h.rgb, 0x000000) }
        #expect(p.hover2 == p.selected)
        #expect(lum(p.bg0) < lum(p.bg1) && lum(p.bg1) < lum(p.bg2))
        #expect(lum(p.bg1) < lum(p.hover) && lum(p.hover) < lum(p.hover2))
    }

    /// §2.1: every spacing is on the 4 pt grid, from 4 to 32; the icon gap is the one exception.
    @Test func spacingIsOnTheGrid() {
        let space = [Theme.Space.s1, Theme.Space.s2, Theme.Space.s3, Theme.Space.s4, Theme.Space.s5, Theme.Space.s6, Theme.Space.s8]
        #expect(space.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
        #expect(space == space.sorted() && Set(space).count == space.count)
        #expect(space.first == 4 && space.last == 32)
        #expect(Theme.Space.iconGap.truncatingRemainder(dividingBy: 4) != 0)
    }

    /// §2.3: control < popover < window; the segment item nests in its track (control + 1) minus the padding 2.
    @Test func radiiNest() {
        #expect(Theme.Radius.control < Theme.Radius.popover && Theme.Radius.popover < Theme.Radius.window)
        #expect(Theme.Radius.segmentItem == Theme.Radius.control + 1 - 2)
    }

    /// §2.4: controls fit their rows and bars, the tab is centred in its strip, a card row is a regular control + 6 / 6;
    /// every height is even, so centred content sits on whole points.
    @Test func heightsFit() {
        let H = Theme.Height.self
        let all = [H.controlRegular, H.controlSmall, H.rowSidebar, H.rowList, H.rowLarge, H.barToolbar, H.barTabs, H.tab, H.barPane, H.cardRow]
        #expect(all.allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 })
        #expect(H.controlSmall < H.controlRegular)
        #expect(H.controlSmall <= H.rowList && H.rowList <= H.rowSidebar && H.rowSidebar <= H.rowLarge)
        #expect(H.controlRegular <= H.rowSidebar && H.controlRegular <= H.barPane && H.controlRegular < H.barToolbar)
        #expect(H.tab < H.barTabs && (H.barTabs - H.tab).truncatingRemainder(dividingBy: 2) == 0)
        #expect(H.cardRow == H.controlRegular + 2 * 6)
    }

    /// §2.5: toolbar > row > inline icons, each fitting the control it sits in; dots below the inline icon.
    @Test func iconsFit() {
        let I = Theme.Icon.self
        #expect(I.toolbar > I.row && I.row > I.inline)
        #expect(I.toolbar < Theme.Height.controlRegular && I.row < Theme.Height.rowList && I.inline < Theme.Height.controlSmall)
        #expect(I.tabDot < I.statusDot && I.statusDot < I.inline)
        #expect([I.toolbar, I.row, I.inline, I.statusDot, I.tabDot].allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 })
    }

    /// §2.7: the only four opacities.
    @Test func fourOpacities() {
        #expect([Theme.Opacity.inactive, Theme.Opacity.fill, Theme.Opacity.ring, Theme.Opacity.scrim] == [0.4, 0.15, 0.25, 0.35])
        #expect(Theme.Typography.body.nsFont().pointSize == 13)
        #expect(Theme.Typography.mono.nsFont(.semibold).isFixedPitch)
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(contrastRatio(0xffffff, 0x000000) - 21) < 0.01)
        #expect(abs(contrastRatio(0x777777, 0xffffff) - 4.48) < 0.01)
    }

    /// Tokens are read through the observable theme holder, so a SwiftUI body that uses one redraws on a switch.
    /// (Other suites run in parallel and read the global theme, so a separate holder is switched here.)
    @Test func tokensObserveTheTheme() {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag(), holder = Theme.Selection()
        withObservationTracking { _ = holder.theme } onChange: { flag.fired = true }
        holder.theme = .graphite
        #expect(flag.fired)
        #expect(cssHex(Theme.bg0) == ThemePalette.of(Theme.current).bg0.css)
        #expect(Theme.ui.bg0 == Color(nsColor: Theme.ns(ThemePalette.of(Theme.current).bg0)))
    }

    @Test func terminalColorsFollowTheTheme() {
        let c = Theme.terminalColors(of: .of(.graphite))
        #expect(c.background == "232220")
        #expect(c.palette.count == 16)
        #expect(c.palette[1] == "f0605a")
        #expect(c.cursor == "f0975a")
        #expect(Theme.terminalColors(of: .of(.navy)).background == "121826")
    }
}
