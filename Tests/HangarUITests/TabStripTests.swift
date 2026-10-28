import CoreGraphics
import Testing
@testable import HangarUI

/// Tab bar geometry (decision #69): min/max widths, overflow, scroll-into-view, wheel mapping.
@Suite struct TabStripTests {
    let lo = Theme.tabMinWidth, hi = Theme.tabMaxWidth, gap = Theme.tabGap
    /// `+` with its gap; the overflow chevron takes the same again.
    let control = Theme.tabGap + Theme.tabBarButton

    private func total(_ w: [CGFloat]) -> CGFloat { w.reduce(0, +) + gap * CGFloat(max(w.count - 1, 0)) }

    @Test func roomyBarClampsNaturalWidths() {
        let l = TabStrip.layout(natural: [60, 150, 400], width: 2000)
        #expect(l.widths == [lo, 150, hi])
        #expect(!l.overflow)
        #expect(l.viewport == total(l.widths))
        #expect(l.content == l.viewport)
    }

    @Test func crowdedBarShrinksWidestFirst() {
        // Room for 380 of tabs: the 120 one keeps its width, the two wide ones share the rest.
        let room = 380 + 2 * gap
        let l = TabStrip.layout(natural: [200, 120, 300], width: room + control)
        #expect(!l.overflow)
        #expect(l.widths[1] == 120)
        #expect(abs(l.widths[0] - 130) < 0.01 && abs(l.widths[2] - 130) < 0.01)
        #expect(abs(l.viewport - room) < 0.01)
    }

    @Test func manyTabsOverflowAtMinWidth() {
        let l = TabStrip.layout(natural: Array(repeating: 150, count: 23), width: 1000)
        #expect(l.overflow)
        #expect(l.widths.allSatisfy { $0 == lo })
        #expect(l.content == total(l.widths))
        // The scroll area leaves room for the chevron and `+`.
        #expect(l.viewport == 1000 - 2 * control)
    }

    @Test func exactFitDoesNotOverflow() {
        let w: [CGFloat] = [lo, lo, lo]
        let l = TabStrip.layout(natural: w, width: total(w) + control)
        #expect(!l.overflow)
        #expect(TabStrip.layout(natural: w, width: total(w) + control - 1).overflow)
    }

    @Test func noTabs() {
        let l = TabStrip.layout(natural: [], width: 500)
        #expect(l.widths.isEmpty && !l.overflow && l.viewport == 0)
    }

    @Test func revealScrollsTheLeastAndClearsFades() {
        let widths = Array(repeating: lo, count: 20)  // content 20·110 + 19·2 = 2238
        let viewport: CGFloat = 500
        let m = Theme.tabFadeWidth
        let start = { (i: Int) in CGFloat(i) * (lo + gap) }
        // Already in view: no scroll.
        #expect(TabStrip.reveal(index: 2, widths: widths, offset: 0, viewport: viewport) == 0)
        // Off to the right: its end (plus the fade) lands on the right edge.
        #expect(TabStrip.reveal(index: 10, widths: widths, offset: 0, viewport: viewport) == start(10) + lo + m - viewport)
        // Off to the left: its start (minus the fade) lands on the left edge.
        #expect(TabStrip.reveal(index: 3, widths: widths, offset: 1000, viewport: viewport) == start(3) - m)
        // First and last tabs: clamped to the content's ends.
        #expect(TabStrip.reveal(index: 0, widths: widths, offset: 1000, viewport: viewport) == 0)
        #expect(TabStrip.reveal(index: 19, widths: widths, offset: 0, viewport: viewport) == total(widths) - viewport)
        // Nothing to scroll when everything fits.
        #expect(TabStrip.reveal(index: 1, widths: [lo, lo], offset: 40, viewport: viewport) == 0)
    }

    @Test func clampKeepsOffsetInsideContent() {
        #expect(TabStrip.clamp(-5, viewport: 100, content: 300) == 0)
        #expect(TabStrip.clamp(250, viewport: 100, content: 300) == 200)
        #expect(TabStrip.clamp(50, viewport: 400, content: 300) == 0)
        #expect(TabStrip.clamp(80, viewport: 100, content: 300) == 80)
    }

    @Test func wheelMapsVerticalToHorizontal() {
        // Trackpad: points as they come; the dominant axis wins.
        #expect(TabStrip.wheel(dx: -12, dy: 3, precise: true) == -12)
        #expect(TabStrip.wheel(dx: 1, dy: -20, precise: true) == -20)
        // Mouse wheel: lines → points.
        #expect(TabStrip.wheel(dx: 0, dy: -2, precise: false) == -2 * Theme.tabWheelLine)
        #expect(TabStrip.wheel(dx: 0, dy: 0, precise: false) == 0)
    }

    /// ⌘1…⌘8 are positional; ⌘9 is the last tab (VS Code, browsers).
    @Test func tabNumberNineIsTheLastTab() {
        #expect(tabIndex(number: 1, count: 25) == 0)
        #expect(tabIndex(number: 8, count: 25) == 7)
        #expect(tabIndex(number: 9, count: 25) == 24)
        #expect(tabIndex(number: 9, count: 3) == 2)
        #expect(tabIndex(number: 5, count: 3) == nil)
        #expect(tabIndex(number: 9, count: 0) == nil)
    }

    /// File tabs (#83) keep their whole name, as in VS Code: as wide as the name, past the agent tabs' max, up to
    /// `fileTabMaxWidth`; a crowded strip scrolls instead of truncating "useCheckoutButton.ts" to "useCheckoutButton.…".
    /// Agent / shell tabs stop at `tabMaxWidth`.
    @Test func fileTabsKeepTheirNames() {
        let natural: [CGFloat] = [260, 126, 300, 900]
        let whole = [false, true, true, true]
        let l = TabStrip.layout(natural: natural, whole: whole, width: 500)
        #expect(l.overflow)
        #expect(l.widths == [Theme.tabMinWidth, 126, 300, Theme.fileTabMaxWidth])
        let roomy = TabStrip.layout(natural: natural, whole: whole, width: 3000)
        #expect(roomy.widths == [Theme.tabMaxWidth, 126, 300, Theme.fileTabMaxWidth] && !roomy.overflow)
    }

    /// OSC titles lose the agent's leading status glyph (the tab already shows the agent icon and dot).
    @Test func terminalTitleDropsStatusGlyphs() {
        #expect(terminalTitle("✳ JS-14684") == "JS-14684")
        #expect(terminalTitle("⠋ Working on it") == "Working on it")
        #expect(terminalTitle("✻  claude") == "claude")
        #expect(terminalTitle("· JS-1 · fix") == "JS-1 · fix")
        #expect(terminalTitle("✶✢ x") == "x")
        #expect(terminalTitle("~/dev/app") == "~/dev/app")
        #expect(terminalTitle("vim a.ts") == "vim a.ts")
        #expect(terminalTitle("✳ ") == "")
        #expect(terminalTitle("✽ ✺ ✹ ✷ ✸ • ∙ ⋅ x") == "x")
        #expect(terminalTitle("✳\u{FE0F} x") == "x")
    }

    @Test func terminalTitleKeepsARealLeadingSymbol() {
        #expect(terminalTitle("* scratch") == "* scratch")
        #expect(terminalTitle("★ favourites") == "★ favourites")
        #expect(terminalTitle("☀ weather") == "☀ weather")
        #expect(terminalTitle("✳ ★ x") == "★ x")
        #expect(terminalTitle("● dot") == "● dot")
    }

    /// Reorder: a neighbour gives way when the dragged tab's leading / trailing edge passes its middle; the last slot
    /// (after the last tab, index == the others' count) is reachable without the dragged tab's centre passing it.
    @Test func reorderReachesTheLastSlot() {
        let w: [CGFloat] = [110, 165, 181]
        let lastMid = 110 + gap + 165 + gap + 181 / 2
        #expect(TabStrip.reorderIndex(widths: w, from: 0, dx: 0) == 0)
        #expect(TabStrip.reorderIndex(widths: w, from: 0, dx: lastMid - 110 + 1) == 2)  // trailing edge past the last's middle
        #expect(TabStrip.reorderIndex(widths: w, from: 0, dx: lastMid - 110 - 1) == 1)
        #expect(TabStrip.reorderIndex(widths: w, from: 1, dx: 181 / 2 + gap + 1) == 2)  // the next-to-last to the end
        #expect(TabStrip.reorderIndex(widths: w, from: 2, dx: -(110 + gap + 165 + gap - 110 / 2) - 1) == 0)  // leading edge past the first's middle
        #expect(TabStrip.reorderIndex(widths: w, from: 2, dx: -10) == 2)
    }

    /// Reorder: the tabs between the dragged one and its slot part by its width, opening the gap where it lands.
    @Test func neighboursPartToOpenTheSlot() {
        let w: [CGFloat] = [100, 120, 80, 90]
        // Tab 0 dragged to slot 2 (after tabs 1 and 2): they move left by its width.
        #expect(TabStrip.shifts(widths: w, from: 0, to: 2) == [0, -(100 + gap), -(100 + gap), 0])
        #expect(TabStrip.slotX(widths: w, from: 0, to: 2) == 120 + 80 + 2 * gap)
        // Tab 3 dragged to slot 1: tabs 1 and 2 move right.
        #expect(TabStrip.shifts(widths: w, from: 3, to: 1) == [0, 90 + gap, 90 + gap, 0])
        #expect(TabStrip.slotX(widths: w, from: 3, to: 1) == 100 + gap)
        #expect(TabStrip.shifts(widths: w, from: 1, to: 1) == [0, 0, 0, 0])
    }
}
