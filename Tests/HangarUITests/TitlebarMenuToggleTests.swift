import Foundation
import Testing
@testable import HangarUI

@MainActor @Suite struct TitlebarMenuToggleTests {
    @Test func offsetFollowsTheTrafficLights() {
        #expect(titlebarOffset(lightsCenterY: 16, barHeight: 38) == -3)
        #expect(titlebarOffset(lightsCenterY: nil, barHeight: 38) == 0)
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
