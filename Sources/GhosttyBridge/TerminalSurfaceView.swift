import AppKit
import Exec
import GhosttyKit

/// One Ghostty terminal surface (own pty + process). Keyboard/mouse/IME live in TerminalSurfaceView+Input.swift.
@MainActor public final class TerminalSurfaceView: NSView {
    public var onTitleChange: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onDesktopNotification: ((String, String) -> Void)?  // title, body
    public var onChildExit: ((Int32) -> Void)?  // -1 = exit code unknown

    // nonisolated(unsafe): freed in deinit, which is nonisolated; only touched on main.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    nonisolated(unsafe) var eventMonitor: Any?
    nonisolated(unsafe) private static var live = Set<UnsafeMutableRawPointer>()

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
        Self.live.insert(me)
        guard let app = GhosttyApp.shared.app else {
            ghosttyLog.error("TerminalSurfaceView created before GhosttyApp.start()")
            return
        }
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
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        let me = Unmanaged.passUnretained(self).toOpaque()
        nonisolated(unsafe) let s = surface
        nonisolated(unsafe) let monitor = eventMonitor
        nonisolated(unsafe) let release = {
            Self.live.remove(me)
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let s { ghostty_surface_free(s) }
        }
        if Thread.isMainThread { release() } else { DispatchQueue.main.async { release() } }
    }

    /// Resolves callback userdata; nil if the view is already gone (async hops can outlive it).
    static func from(_ ud: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let ud, live.contains(ud) else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    // MARK: Public API

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
        let alert = NSAlert()
        if request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ {
            alert.messageText = "A program wants to read the clipboard"
        } else {
            alert.messageText = "Paste text that may run commands?"
        }
        alert.informativeText = String(text.prefix(500))
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            let data = response == .alertFirstButtonReturn ? text : ""
            data.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: complete) } else { complete(alert.runModal()) }
    }

    private func shellEscape(_ path: String) -> String {
        let special = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    // MARK: Layout, scale, focus, visibility

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focusDidChange(true) }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focusDidChange(false) }
        return ok
    }

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

    private func updateOcclusion() {
        guard let surface else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        ghostty_surface_set_occlusion(surface, visible && windowVisible)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }
}
