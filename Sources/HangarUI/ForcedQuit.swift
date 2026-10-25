import AppKit

/// SIGTERM / shutdown: an attached sheet or a modal session (`runModal` of «Выбрать…») holds `terminate`
/// until someone presses Esc. Ends every sheet (innermost first) with `.abort` and aborts the modal loop.
@MainActor
public func dismissModalsForForcedQuit(windows: [NSWindow] = NSApp.windows) {
    func end(_ window: NSWindow) {
        while let sheet = window.attachedSheet {
            end(sheet)
            window.endSheet(sheet, returnCode: .abort)
            guard window.attachedSheet !== sheet else { sheet.orderOut(nil); break }  // never spin on a stuck sheet
        }
    }
    for window in windows where window.sheetParent == nil { end(window) }
    if NSApp?.modalWindow != nil { NSApp.abortModal() }
}
