import AppKit
import Carbon
import GhosttyKit

// Keyboard, IME, mouse and scroll — ported from Ghostty's macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift.
extension TerminalSurfaceView {
    func installEventMonitor() {
        // Local monitors run on the main thread.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return event.type == .keyUp ? self.localKeyUp(event) : self.localLeftMouseDown(event)
            }
            return consumed ? nil : event
        }
    }

    // Command+key keyUp never reaches the responder chain; Ghostty still wants the release.
    private func localKeyUp(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), focused else { return false }
        keyUp(with: event)
        return true
    }

    // A click that only moves focus into this surface must not reach the terminal as a mouse press.
    private func localLeftMouseDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              hitTest(convert(event.locationInWindow, from: nil)) === self else { return false }
        suppressNextLeftMouseUp = false
        guard window.firstResponder !== self else { return false }
        let activeAlready = NSApp.isActive && window.isKeyWindow
        window.makeFirstResponder(self)
        // When the window is already key, the click only moves focus; otherwise AppKit needs it to activate the window.
        suppressNextLeftMouseUp = activeAlready
        return activeAlready
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }
        hadInput = true
        // ⌘V that skipped performKeyEquivalent (window not key) would hit Ghostty's own super+v paste.
        if Int(event.keyCode) == kVK_ANSI_V, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           onPaste?() == true { return }

        // Option-as-alt etc.: Ghostty decides which mods take part in text translation.
        let ghosttyTranslation = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if ghosttyTranslation.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the original event when possible: IME (e.g. Korean) breaks with a synthesized copy.
        let translationEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let layoutBefore = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // The key switched the input source (e.g. a layout shortcut): don't send it to the terminal.
        if !markedTextBefore && layoutBefore != Self.keyboardLayoutID { return }
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list { _ = keyAction(action, event: event, translationEvent: translationEvent, text: text) }
        } else {
            // Composing also when preedit was just cleared (e.g. backspace cancels a Japanese composition).
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: Self.ghosttyCharacters(translationEvent),
                          composing: markedText.length > 0 || markedTextBefore)
        }
    }

    public override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        // ⌘C/⌘V/⌘A by keyCode so they work in any layout (Russian included).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command {
            let binding: String? = switch Int(event.keyCode) {
            case kVK_ANSI_C: "copy_to_clipboard"
            case kVK_ANSI_V: "paste_from_clipboard"
            case kVK_ANSI_A: "select_all"
            default: nil
            }
            if Int(event.keyCode) == kVK_ANSI_V, onPaste?() == true { return true }
            if let binding {
                _ = ghostty_surface_binding_action(surface, binding, UInt(binding.utf8.count))
                return true
            }
        }

        // The user's Ghostty keybinds.
        var ev = Self.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim instead of the default context-menu equivalent.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // C-/ beeps in AppKit; terminals expect C-_.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }  // synthetic AppKit events (e.g. Cmd+. → cancel)
            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }
            // Second pass of the same event (sent back by doCommand): encode it in keyDown.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: finalEvent)
        return true
    }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch Int(event.keyCode) {
        case kVK_CapsLock: mod = GHOSTTY_MODS_CAPS.rawValue
        case kVK_Shift, kVK_RightShift: mod = GHOSTTY_MODS_SHIFT.rawValue
        case kVK_Control, kVK_RightControl: mod = GHOSTTY_MODS_CTRL.rawValue
        case kVK_Option, kVK_RightOption: mod = GHOSTTY_MODS_ALT.rawValue
        case kVK_Command, kVK_RightCommand: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        var action = GHOSTTY_ACTION_RELEASE
        if Self.mods(event.modifierFlags).rawValue & mod != 0 {
            // Pressed only if this side is down; otherwise it's the other side being released.
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch Int(event.keyCode) {
            case kVK_RightShift: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case kVK_RightControl: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case kVK_RightOption: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case kVK_RightCommand: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = Self.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        // Single control characters are encoded by Ghostty itself (else ctrl+enter breaks).
        if let text, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    static func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                         translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.mods = mods(event.modifierFlags)
        // Heuristic from Ghostty: control and command never contribute to text translation.
        ev.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        if event.type == .keyDown || event.type == .keyUp,
           let cp = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }  // function keys (PUA)
        }
        return chars
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: frame, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    public override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp { suppressNextLeftMouseUp = false; return }
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    public override func otherMouseDown(with event: NSEvent) { otherButton(event, GHOSTTY_MOUSE_PRESS) }
    public override func otherMouseUp(with event: NSEvent) { otherButton(event, GHOSTTY_MOUSE_RELEASE) }

    private func otherButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e) {
        guard let surface else { return }
        let button: ghostty_input_mouse_button_e = switch event.buttonNumber {
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_FOUR
        case 4: GHOSTTY_MOUSE_FIVE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)  // resets the -1/-1 set on exit; mouse reporting depends on it
    }

    public override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }  // drags keep reporting
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    public override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.mods(event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }  // Ghostty's subjective trackpad speed-up
        let momentum: Int32 = switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        // ghostty_input_scroll_mods_t: bit 0 = precision, bits 1-3 = momentum phase.
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: Edit menu actions (responder chain)

    @objc func copy(_ sender: Any?) { perform(binding: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { if onPaste?() != true { perform(binding: "paste_from_clipboard") } }
    @objc public override func selectAll(_ sender: Any?) { perform(binding: "select_all") }

    private func perform(binding: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, binding, UInt(binding.utf8.count))
    }
}

// MARK: - NSTextInputClient (IME / dead keys / marked text)

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    public func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. layout switched mid-composition) the preedit must update now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME candidate window goes: Ghostty reports the cursor cell (top-left origin).
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 {
            w = 0  // dictation indicator expects a zero-width caret
            x += Double(cellSize.width) * Double(range.location)
        }
        let viewRect = NSRect(x: x, y: frame.height - y, width: w, height: max(h, Double(cellSize.height)))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil, let surface else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        // Inside keyDown: collect and send as key events with text there.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        let len = chars.utf8.count
        if len > 0 { chars.withCString { ghostty_surface_text(surface, $0, UInt(len)) } }
    }

    /// Swallows unhandled selectors (no NSBeep) and re-dispatches Cmd keys bounced through AppKit's text system.
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)): perform(binding: "scroll_to_top")
        case #selector(moveToEndOfDocument(_:)): perform(binding: "scroll_to_bottom")
        default: break
        }
    }

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ghostty_surface_preedit(surface, $0, UInt(str.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
