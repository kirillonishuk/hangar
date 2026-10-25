import SwiftUI
import Testing
@testable import HangarUI

@MainActor @Suite struct KeepAwakeLookTests {
    /// ☕ row and rail: on and off must not look alike; the dot only while the assertion is held.
    @Test func stateMapsToStyle() {
        let off = keepAwakeLook(enabled: false, held: false)
        #expect(off == KeepAwakeLook(on: false, tint: Theme.ui.text3, label: Theme.ui.text3, dot: false))
        // Held but switched off (released on the next update): still shown off.
        #expect(keepAwakeLook(enabled: false, held: true) == off)
        #expect(keepAwakeLook(enabled: true, held: false) == KeepAwakeLook(on: true, tint: Theme.ui.accent, label: Theme.ui.textStrong, dot: false))
        #expect(keepAwakeLook(enabled: true, held: true) == KeepAwakeLook(on: true, tint: Theme.ui.accent, label: Theme.ui.textStrong, dot: true))
    }
}
