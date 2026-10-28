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
    public var onBell: (() -> Void)?
    public var onDesktopNotification: ((String, String) -> Void)?  // title, body
    public var onChildExit: ((Int32) -> Void)?  // -1 = exit code unknown
    /// Became first responder (click or programmatic focus).
    public var onFocus: (() -> Void)?
    /// ⌘V: true = the owner handled it (e.g. sent ⌃V for an image), so no text paste.
    public var onPaste: (() -> Bool)?

    // nonisolated(unsafe): freed in deinit, which is nonisolated; only touched on main.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    nonisolated(unsafe) var eventMonitor: Any?
    /// Views whose surface may still be used by callbacks; locked so deinit can drop itself synchronously on any thread.
    nonisolated private static let live = OSAllocatedUnfairLock(initialState: Set<UInt>())
    /// Open clipboard confirmation; must be answered (denied) before the surface is freed.
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

    enum Event {
        case title(String), bell, notification(title: String, body: String)
        case commandFinished(Int16), childExited
        case mouseShape(ghostty_action_mouse_shape_e), mouseVisible(Bool)
        case cellSize(width: UInt32, height: UInt32), openURL(String)
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
        let len = text.utf8.count
        guard len > 0 else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(len)) }
    }

    public func sendEnter() {
        guard let surface else { return }
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

    // MARK: Ghostty actions

    func handle(_ event: Event) -> Bool {
        switch event {
        case .title(let t): onTitleChange?(t)
        case .bell: onBell?()
        case .notification(let title, let body): onDesktopNotification?(title, body)
        case .commandFinished(let code):
            lastCommandExit = code >= 0 ? Int32(code) : nil
        case .childExited:
            // Ghostty runs commands via login(1), so its own exit code is always 0 (decision #26).
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
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let str = urls.isEmpty ? pb.string(forType: .string)
            : urls.map { $0.isFileURL ? shellEscape($0.path) : $0.absoluteString }.joined(separator: " ")
        // false lets performable paste bindings fall through to the terminal.
        guard let str else { return false }
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

    private func shellEscape(_ path: String) -> String {
        let special = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
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

/// Keys `sendKey` can press.
public enum SurfaceKey: Sendable {
    case escape  // kVK_Escape 53
    case colon   // kVK_ANSI_Semicolon 41 + shift, text ":"
    case tab, backspace, up, down, left, right
    case ctrlC   // kVK_ANSI_C 8 + ctrl, codepoint "c"
    case ctrlD   // kVK_ANSI_D 2 + ctrl, codepoint "d"
    case ctrlV   // kVK_ANSI_V 9 + ctrl, codepoint "v": claude/codex paste a clipboard image
}
