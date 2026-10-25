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

    /// A status dot takes title room: its tab's minimum grows by the dot, so «claude» with a dot is not cut to «cl…».
    @Test func statusDotWidensTheMinimum() {
        let dotted = lo + Theme.statusDot + Theme.rowEndGap
        #expect(TabStrip.minWidth(dot: true) == dotted && TabStrip.minWidth(dot: false) == lo)
        let many = TabStrip.layout(natural: Array(repeating: 150, count: 23), dots: [true] + Array(repeating: false, count: 22), width: 1000)
        #expect(many.overflow)
        #expect(many.widths[0] == dotted)
        #expect(many.widths.dropFirst().allSatisfy { $0 == lo })
        #expect(many.content == total(many.widths))
        // Crowded but fitting: the shared cap never cuts a dotted tab below its own minimum.
        let room = dotted + lo + 10 + gap  // an equal split (cap 123) would cut the dotted tab
        let l = TabStrip.layout(natural: [300, 300], dots: [true, false], width: room + control)
        #expect(!l.overflow)
        #expect(l.widths[0] == dotted)
        #expect(abs(l.widths[1] - (lo + 10)) < 0.01)
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
}
