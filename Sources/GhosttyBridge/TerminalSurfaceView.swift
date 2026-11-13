import AppKit
import Exec
import GhosttyKit
import os

/// One Ghostty terminal surface (own pty + process). Keyboard/mouse/IME live in TerminalSurfaceView+Input.swift.
/// Texts of the clipboard confirmation; the app supplies them localized (the bridge has no UI strings).
public struct ClipboardPromptText: Sendable {
    public var readClipboard: String
    public var pasteUnsafe: String
    public var allow: String
    public var cancel: String
    public init(readClipboard: String, pasteUnsafe: String, allow: String, cancel: String) {
        self.readClipboard = readClipboard
        self.pasteUnsafe = pasteUnsafe
        self.allow = allow
        self.cancel = cancel
    }
}

@MainActor public final class TerminalSurfaceView: NSView {
    /// Read when a dialog opens, so a language switch applies to the next one.
    public static var clipboardPromptText: () -> ClipboardPromptText = {
        ClipboardPromptText(readClipboard: "A program wants to read the clipboard",
                            pasteUnsafe: "Paste text that may run commands?", allow: "Allow", cancel: "Cancel")
    }

    public var onTitleChange: ((String) -> Void)?
    /// The shell's folder (OSC 7): untrusted text from the program in the terminal.
    public var onPwd: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onDesktopNotification: ((String, String) -> Void)?  // title, body
    public var onChildExit: ((Int32) -> Void)?  // -1 = exit code unknown
    /// Became first responder (click or programmatic focus).
    public var onFocus: (() -> Void)?
    /// ⌘V: true = the owner handled it (e.g. sent ⌃V for an image), so no text paste.
    public var onPaste: (() -> Bool)?
    /// Ghostty's scrollback search (HD-159): the host shows a find bar and drives it with `search` / `navigateSearch` / `endSearch`.
    public var onSearch: ((SearchEvent) -> Void)?
    /// Something was typed, pasted or sent into this surface (a password, a command): a new surface per launch.
    public internal(set) var hadInput = false

    // nonisolated(unsafe): freed in deinit, which is nonisolated; only touched on main.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    nonisolated(unsafe) var eventMonitor: Any?
    /// Views whose surface may still be used by callbacks; locked so deinit can drop itself synchronously on any thread.
    nonisolated private static let live = OSAllocatedUnfairLock(initialState: Set<UInt>())
    /// Open clipboard confirmation; must be answered (denied) before the surface is freed.
    /// A drop's text for the paste it starts (HD-159): the next clipboard read takes it instead of the clipboard.
    private var dropText: String?
    nonisolated(unsafe) private var pendingClipboard: (alert: NSAlert, state: UnsafeMutableRawPointer?)?

    private var lastCommandExit: Int32?
    private var visible = true
    private var cursor: NSCursor = .iBeam
    var cellSize = NSSize.zero
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var lastPerformKeyEvent: TimeInterval?
    var suppressNextLeftMouseUp = false
    var focused = false
    /// AXValue (whole screen text) for a moment: dictation apps query it many times per focus change.
    var accessibilityTextCache: (text: String, at: TimeInterval)?

    enum Event {
        case title(String), bell, notification(title: String, body: String)
        case commandFinished(Int16), childExited
        case mouseShape(ghostty_action_mouse_shape_e), mouseVisible(Bool)
        case cellSize(width: UInt32, height: UInt32), openURL(String)
        case pwd(String)
        case search(SearchEvent)
    }

    public init(spec: LaunchSpec) {
        // Non-zero so the renderer has a drawable before the first layout.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let key = UInt(bitPattern: me)
        _ = Self.live.withLock { $0.insert(key) }
        guard let app = GhosttyApp.shared.app else {
            ghosttyLog.error("TerminalSurfaceView created before GhosttyApp.start()")
            return
        }
        #if DEBUG
        // Verification seam: creation fails while the file named by HANGAR_DEBUG_FAIL_SURFACE exists.
        if let path = ProcessInfo.processInfo.environment["HANGAR_DEBUG_FAIL_SURFACE"], FileManager.default.fileExists(atPath: path) {
            ghosttyLog.error("ghostty_surface_new skipped (HANGAR_DEBUG_FAIL_SURFACE)")
            return
        }
        #endif
        var cfg = ghostty_surface_config_new()
        cfg.userdata = me
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: me))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        // Ghostty copies all strings inside ghostty_surface_new; they only need to outlive the call.
        let owned = [spec.command, spec.cwd] + spec.env.flatMap { [$0.key, $0.value] }
        let cstrs = owned.map { strdup($0)! }
        defer { cstrs.forEach { free($0) } }
        cfg.command = UnsafePointer(cstrs[0])
        cfg.working_directory = UnsafePointer(cstrs[1])
        var envs = stride(from: 2, to: cstrs.count, by: 2).map {
            ghostty_env_var_s(key: cstrs[$0], value: cstrs[$0 + 1])
        }
        surface = envs.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }
        guard surface != nil else {
            ghosttyLog.error("ghostty_surface_new failed")
            return
        }
        updateTrackingAreas()
        installEventMonitor()
        registerForDraggedTypes(Self.dropTypes)
        // Ghostty creates surfaces focused (display link + cursor blink running); match `focused = false`.
        ghostty_surface_set_focus(surface, false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Unregister first and synchronously: from(ud) must never resolve a view that is tearing down.
        let key = UInt(bitPattern: me)
        _ = Self.live.withLock { $0.remove(key) }
        nonisolated(unsafe) let s = surface
        nonisolated(unsafe) let monitor = eventMonitor
        nonisolated(unsafe) let pendingState = pendingClipboard.map { $0.state }
        nonisolated(unsafe) let release = {
            if let monitor { NSEvent.removeMonitor(monitor) }
            guard let s else { return }
            if let pendingState { "".withCString { ghostty_surface_complete_clipboard_request(s, $0, pendingState, true) } }
            ghostty_surface_free(s)
        }
        if Thread.isMainThread { release() } else { DispatchQueue.main.async { release() } }
    }

    /// Resolves callback userdata; nil if the view is already gone (async hops can outlive it).
    static func from(_ ud: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let ud else { return nil }
        let key = UInt(bitPattern: ud)
        guard live.withLock({ $0.contains(key) }) else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    /// At quit: frees every surface, so Ghostty SIGHUPs each child's group until it exits. The pty hangup
    /// when the app exits alone misses a child that is still starting (login → zsh), and it outlives the app.
    public static func freeAll() {
        let keys = live.withLock { keys in defer { keys.removeAll() }; return keys }
        for key in keys {
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(UnsafeRawPointer(bitPattern: key)!).takeUnretainedValue()
            guard let s = view.surface else { continue }
            view.surface = nil
            if let state = view.pendingClipboard?.state { "".withCString { ghostty_surface_complete_clipboard_request(s, $0, state, true) } }
            view.pendingClipboard = nil
            ghostty_surface_free(s)
        }
    }

    // MARK: Public API

    /// False when Ghostty could not create the surface (app not started, no display, …); the owner may retry with a new view.
    public var isAlive: Bool { surface != nil }

    /// Hidden surfaces skip GPU frames (decision: occlusion is Ghostty's render pause).
    public func setVisible(_ visible: Bool) {
        self.visible = visible
        isHidden = !visible
        updateOcclusion()
    }

    /// Paste semantics (bracketed paste): a trailing "\r" does not submit; use sendEnter().
    public func sendText(_ text: String) {
        guard let surface else { return }
        hadInput = true
        let len = text.utf8.count
        guard len > 0 else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(len)) }
    }

    public func sendEnter() {
        guard let surface else { return }
        hadInput = true
        var k = ghostty_input_key_s()
        k.keycode = 36  // kVK_Return
        k.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, k)
        k.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, k)
    }

    /// A real key press + release (not a paste), e.g. Esc or Ctrl-C from `tabs send`.
    public func sendKey(_ key: SurfaceKey) {
        guard let surface else { return }
        hadInput = true
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS
        switch key {
        case .escape: k.keycode = 53  // kVK_Escape
        case .tab: k.keycode = 48
        case .backspace: k.keycode = 51  // kVK_Delete
        case .up: k.keycode = 126
        case .down: k.keycode = 125
        case .left: k.keycode = 123
        case .right: k.keycode = 124
        case .ctrlC, .ctrlD, .ctrlV:
            let (code, ch): (UInt32, UInt8) = key == .ctrlC ? (8, UInt8(ascii: "c")) : key == .ctrlD ? (2, UInt8(ascii: "d")) : (9, UInt8(ascii: "v"))
            k.keycode = code  // kVK_ANSI_C / D / V
            k.mods = GHOSTTY_MODS_CTRL
            k.unshifted_codepoint = UInt32(ch)
        case .colon:
            k.keycode = 41  // kVK_ANSI_Semicolon
            k.mods = GHOSTTY_MODS_SHIFT
            k.consumed_mods = GHOSTTY_MODS_SHIFT
            k.unshifted_codepoint = UInt32(UInt8(ascii: ";"))
        }
        if key == .colon {
            _ = ":".withCString { ptr in
                k.text = ptr
                return ghostty_surface_key(surface, k)
            }
            k.text = nil
        } else {
            _ = ghostty_surface_key(surface, k)
        }
        k.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, k)
    }

    /// Whole screen including scrollback.
    public func screenText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    // MARK: Search (HD-159)

    /// Opens the search (Ghostty answers with `.started`); with a search open — the same, so the host refocuses its field.
    public func startSearch() { bindingAction("start_search") }

    /// Searches the scrollback for `needle`; empty stops the search (the bar stays).
    public func search(_ needle: String) { bindingAction("search:" + needle) }

    /// `next`: Ghostty's order (from the bottom up), as its own ↩.
    public func navigateSearch(next: Bool) { bindingAction(next ? "navigate_search:next" : "navigate_search:previous") }

    /// Ends the search; Ghostty answers with `.ended`.
    public func endSearch() { bindingAction("end_search") }

    private func bindingAction(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Ghostty actions

    func handle(_ event: Event) -> Bool {
        switch event {
        case .title(let t): onTitleChange?(t)
        case .pwd(let p): onPwd?(p)
        case .bell: onBell?()
        case .notification(let title, let body): onDesktopNotification?(title, body)
        case .commandFinished(let code):
            lastCommandExit = code >= 0 ? Int32(code) : nil
        case .childExited:
            // Ghostty runs commands via login(1), so its own exit code is always 0 (decision HD-026).
            let code = lastCommandExit ?? -1
            ghosttyLog.info("child exited, code=\(code)")
            onChildExit?(code)
        case .mouseShape(let shape):
            cursor = Self.cursor(for: shape)
            window?.invalidateCursorRects(for: self)
        case .mouseVisible(let v):
            NSCursor.setHiddenUntilMouseMoves(!v)
        case .cellSize(let w, let h):
            cellSize = convertFromBacking(NSSize(width: Double(w), height: Double(h)))
        case .search(let e): onSearch?(e)
        case .openURL(let s):
            guard let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            else { return false }
            NSWorkspace.shared.open(url)
        }
        return true
    }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: .resizeUpDown
        default: .arrow
        }
    }

    // MARK: Clipboard (called from GhosttyApp callbacks)

    func readClipboard(_ location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface, location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
        // A drop's text, once (`insertDropped`), else the clipboard. false lets performable paste bindings fall through.
        let drop = dropText
        dropText = nil
        guard let str = drop ?? Self.pasteText(NSPasteboard.general) else { return false }
        str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    /// Unsafe paste (clipboard-paste-protection) or OSC 52 read: ask the user, never bypass.
    func confirmReadClipboard(_ text: String, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let surface else { return }
        // One dialog at a time (as Ghostty.app); extra requests are denied.
        guard pendingClipboard == nil else {
            "".withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
            return
        }
        let alert = NSAlert()
        let strings = Self.clipboardPromptText()
        alert.messageText = request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ ? strings.readClipboard : strings.pasteUnsafe
        alert.informativeText = String(text.prefix(500))
        alert.addButton(withTitle: strings.allow)
        alert.addButton(withTitle: strings.cancel)
        pendingClipboard = (alert, state)
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.finishClipboardConfirmation(allow: response == .alertFirstButtonReturn, text: text)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: complete) } else { complete(alert.runModal()) }
    }

    /// No-op if already answered (e.g. denied when the view left its window).
    private func finishClipboardConfirmation(allow: Bool, text: String) {
        guard let (_, state) = pendingClipboard else { return }
        pendingClipboard = nil
        guard let surface else { return }
        (allow ? text : "").withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
    }

    /// Leaving the window (tab closed): deny the open request and close its sheet while the surface is still alive.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let alert = pendingClipboard?.alert {
            finishClipboardConfirmation(allow: false, text: "")
            window?.endSheet(alert.window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// What ⌘V and a drop insert: URLs (Finder files, screenshots, inspector rows) as shell-escaped paths
    /// (other URLs as they are), joined by spaces; otherwise the text; nil — nothing to insert.
    nonisolated static func pasteText(_ pb: NSPasteboard) -> String? {
        let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return pb.string(forType: .string) }
        return urls.map { $0.isFileURL ? shellEscape($0.path) : $0.absoluteString }.joined(separator: " ")
    }

    /// Backslashes before shell specials; a name with a control character (newline, CR, ESC, C1) is `$'…'`-quoted with
    /// those as `\xHH` bytes, so a dropped file named `a\ncurl …` is one word, never a second command line.
    nonisolated static func shellEscape(_ path: String) -> String {
        func isControl(_ u: Unicode.Scalar) -> Bool { u.value < 0x20 || (0x7f...0x9f).contains(u.value) }
        if path.unicodeScalars.contains(where: isControl) {
            let body = path.unicodeScalars.map { u -> String in
                if u == "\\" { return "\\\\" }
                // `'` and `!` as bytes too: interactive bash expands `!!` even inside $'…' (history comes first).
                guard isControl(u) || u == "'" || u == "!" else { return String(u) }
                return String(u).utf8.map { String(format: "\\x%02x", $0) }.joined()
            }.joined()
            return "$'" + body + "'"
        }
        let special = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    // MARK: Drop (HD-159)

    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        surface != nil && Self.pasteText(sender.draggingPasteboard) != nil ? .copy : []
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        insertDropped(sender.draggingPasteboard)
    }

    /// The drop's text goes in through Ghostty's own paste, exactly as ⌘V: bracketed, never submitted, and text Ghostty
    /// finds unsafe (a newline, the end of a bracketed paste) asks first. The terminal takes the keyboard.
    @discardableResult public func insertDropped(_ pb: NSPasteboard) -> Bool {
        guard let surface, let text = Self.pasteText(pb) else { return false }
        hadInput = true
        dropText = text
        let binding = "paste_from_clipboard"
        // Ghostty reads the "clipboard" (`readClipboard`, which hands over `dropText` once); not run — nothing waits for it.
        guard ghostty_surface_binding_action(surface, binding, UInt(binding.utf8.count)) else {
            dropText = nil
            return false
        }
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Layout, scale, focus, visibility

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            focusDidChange(window?.isKeyWindow ?? false)  // focused = first responder in the key window
            onFocus?()
        }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focusDidChange(false) }
        return ok
    }

    #if DEBUG
    /// Verification runs never activate the app, so its window is never key: focus the surface as a key window would.
    public func debugFocus() { focusDidChange(true) }
    #endif

    func focusDidChange(_ focused: Bool) {
        guard let surface, self.focused != focused else { return }
        self.focused = focused
        if !focused { suppressNextLeftMouseUp = false }
        ghostty_surface_set_focus(surface, focused)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidChangeScreen), name: NSWindow.didChangeScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(windowOcclusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        nc.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        nc.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
        windowDidChangeScreen()
        updateOcclusion()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)  // avoid a scale animation of the layer contents
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        let px = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    @objc private func windowDidChangeScreen() {
        guard let surface, let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        else { return }
        ghostty_surface_set_display_id(surface, id)  // vsync follows the display
        DispatchQueue.main.async { [weak self] in self?.viewDidChangeBackingProperties() }
    }

    @objc private func windowOcclusionChanged() { updateOcclusion() }

    /// Like Ghostty's syncFocusToSurfaceTree: a non-key window must not keep the display link and blink running.
    @objc private func windowKeyChanged() { focusDidChange(window?.isKeyWindow == true && window?.firstResponder === self) }

    private func updateOcclusion() {
        guard let surface else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        ghostty_surface_set_occlusion(surface, visible && windowVisible)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }
}

/// Ghostty's search state, reported by the surface (`onSearch`).
public enum SearchEvent: Equatable, Sendable {
    /// Opened (or asked again); `needle` — the selection for ⌘E, else empty.
    case started(needle: String)
    case ended
    /// Matches in the scrollback; nil — not searching.
    case total(Int?)
    /// Index of the selected match; nil — none selected yet.
    case selected(Int?)
}

/// Keys `sendKey` can press.
public enum SurfaceKey: Sendable {
    case escape  // kVK_Escape 53
    case colon   // kVK_ANSI_Semicolon 41 + shift, text ":"
    case tab, backspace, up, down, left, right
    case ctrlC   // kVK_ANSI_C 8 + ctrl, codepoint "c"
    case ctrlD   // kVK_ANSI_D 2 + ctrl, codepoint "d"
    case ctrlV   // kVK_ANSI_V 9 + ctrl, codepoint "v": claude/codex paste a clipboard image
}
