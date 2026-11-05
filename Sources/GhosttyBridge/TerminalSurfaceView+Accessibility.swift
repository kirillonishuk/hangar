import AppKit
import GhosttyKit

// Accessibility and Services — ported from Ghostty's SurfaceView_AppKit.swift. Dictation apps (MacWhisper, superwhisper,
// Wispr Flow) start only when the focused AX element is editable text, and some insert through AXSelectedText (HD-148).
extension TerminalSurfaceView {
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityHelp() -> String? { "Terminal content area" }
    public override func accessibilityValue() -> Any? { accessibilityText }
    public override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }
    public override func accessibilitySelectedText() -> String? { selectionText }
    public override func accessibilityNumberOfCharacters() -> Int { accessibilityText.utf16.count }
    public override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityText.utf16.count) }

    public override func accessibilityLine(for index: Int) -> Int {
        accessibilityText.utf16.prefix(index).reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        let text = accessibilityText
        return Range(range, in: text).map { String(text[$0]) }
    }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    /// Text "typed" at the caret by an assistive app: a paste, so bracketed paste applies as with ⌘V.
    public override func setAccessibilitySelectedText(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        unmarkText()
        sendText(text)
        accessibilityTextCache = nil  // the screen changed: a second write from the same base must not diff against the old text
    }

    /// Some clients write back the whole value with their text spliced in; only that inserted part goes to the terminal.
    public override func setAccessibilityValue(_ value: Any?) {
        guard let new = value as? String, let inserted = Self.insertedText(old: accessibilityText, new: new) else { return }
        unmarkText()
        sendText(inserted)
        accessibilityTextCache = nil
    }

    /// `new` is `old` with one run of text inserted → that run; anything else (deletion, rewrite) → nil.
    nonisolated static func insertedText(old: String, new: String) -> String? {
        let o = Array(old.utf16), n = Array(new.utf16)  // not Characters: scrollback can be megabytes, on the main thread
        guard n.count > o.count else { return nil }
        var prefix = 0
        while prefix < o.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix == o.count else { return nil }
        return String(utf16CodeUnits: Array(n[prefix..<(n.count - suffix)]), count: n.count - suffix - prefix)
    }

    /// Whole screen with scrollback, kept briefly so a burst of AX queries reads the terminal once.
    private var accessibilityText: String {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = accessibilityTextCache, now - cache.at < 0.5 { return cache.text }
        let text = screenText() ?? ""
        accessibilityTextCache = (text, now)
        return text
    }

    private var selectionText: String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let str = String(cString: text.text)
        return str.isEmpty ? nil : str
    }
}

// MARK: - Services (send the selection out, receive text back as a paste)

extension TerminalSurfaceView: @preconcurrency NSServicesMenuRequestor {
    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                        returnType: NSPasteboard.PasteboardType?) -> Any? {
        let types: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]
        guard returnType.map(types.contains) ?? true, sendType.map(types.contains) ?? true,
              sendType == nil || (surface.map { ghostty_surface_has_selection($0) } ?? false)
        else { return super.validRequestor(forSendType: sendType, returnType: returnType) }
        return self
    }

    public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let text = selectionText else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text, forType: .string)
    }

    public func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let text = pboard.string(forType: .string) else { return false }
        sendText(text)
        return true
    }
}
