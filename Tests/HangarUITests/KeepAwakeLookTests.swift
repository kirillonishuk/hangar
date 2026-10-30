import Testing
@testable import HangarUI

@MainActor @Suite struct KeepAwakeLookTests {
    /// The setting lives in Settings → Уведомления; the toolbar shows «не спать» only while sleep is actually held.
    @Test func indicatorOnlyWhileHolding() {
        #expect(showsKeepAwake(enabled: true, held: true))
        #expect(!showsKeepAwake(enabled: true, held: false))
        // Held but switched off (released on the next update): not shown.
        #expect(!showsKeepAwake(enabled: false, held: true))
        #expect(!showsKeepAwake(enabled: false, held: false))
    }
}
