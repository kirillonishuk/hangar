import AppKit
import Foundation
import Testing
@testable import HangarUI

@MainActor @Suite struct TitlebarMenuToggleTests {
    @Test func offsetFollowsTheTrafficLights() {
        #expect(titlebarOffset(lightsCenterY: 16, barHeight: 38) == -3)
        #expect(titlebarOffset(lightsCenterY: nil, barHeight: 38) == 0)
    }

    @Test func trafficLightsSitInTheHeadAfterResize() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        for size in [NSSize(width: 800, height: 600), NSSize(width: 1100, height: 700)] {
            window.setContentSize(size)
            TrafficLights.place(in: window)
            let close = try #require(window.standardWindowButton(.closeButton))
            let mini = try #require(window.standardWindowButton(.miniaturizeButton))
            let r = close.convert(close.bounds, to: nil), m = mini.convert(mini.bounds, to: nil)
            #expect(r.minX == Theme.Space.s5 - 1)
            #expect(window.frame.height - r.midY == Theme.Height.barToolbar / 2)
            #expect(m.midY == r.midY && m.minX > r.maxX)
        }
    }

    @Test func clickOnAnchorOfOpenMenuDoesNotReopen() {
        var g = MenuReopenGuard()
        let a = NSObject(), b = NSObject()
        g.dismissed(anchor: ObjectIdentifier(a), byMouseDown: 7)
        let r7 = g.allowsOpen(anchor: ObjectIdentifier(a), event: 7); #expect(!r7)   // the mouseUp of that same click
        let r7b = g.allowsOpen(anchor: ObjectIdentifier(a), event: 7); #expect(r7b)
        g.dismissed(anchor: ObjectIdentifier(a), byMouseDown: 8)
        let r8 = g.allowsOpen(anchor: ObjectIdentifier(b), event: 8); #expect(r8)    // another button opens its menu
        g.dismissed(anchor: ObjectIdentifier(a), byMouseDown: 9)
        let r10 = g.allowsOpen(anchor: ObjectIdentifier(a), event: 10); #expect(r10)   // a later click opens again
    }
}
