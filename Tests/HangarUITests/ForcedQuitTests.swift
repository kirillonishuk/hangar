import AppKit
import Testing
@testable import HangarUI

@MainActor
struct ForcedQuitTests {
    /// SIGTERM with a sheet up: the sheet (and a sheet on it) must go, or `terminate` waits for Esc.
    /// `beginSheet` attaches on a later turn of the run loop.
    private func sheetsSettle() {
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @Test func endsAttachedSheets() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let inner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))  // a sheet needs an ordered-in parent; keep it off screen
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var responses: [NSApplication.ModalResponse] = []
        window.beginSheet(sheet) { responses.append($0) }
        sheetsSettle()
        sheet.beginSheet(inner) { responses.append($0) }
        sheetsSettle()
        #expect(window.attachedSheet === sheet)
        #expect(sheet.attachedSheet === inner)
        dismissModalsForForcedQuit(windows: [window])
        #expect(window.attachedSheet == nil)
        #expect(sheet.attachedSheet == nil)
        sheetsSettle()
        #expect(responses == [.abort, .abort])
    }
}
