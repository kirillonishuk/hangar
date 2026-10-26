import AppKit
import GhosttyKit
import os

let ghosttyLog = Logger(subsystem: "dev.hangar", category: "Ghostty")

public enum GhosttyError: Error { case initFailed, appCreateFailed }

/// The single ghostty_app_t with the user's Ghostty config (~/.config/ghostty/config).
@MainActor public final class GhosttyApp {
    public static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {}

    /// True once `start()` succeeded; surfaces can only be created while running.
    public var isRunning: Bool { app != nil }

    private var padding: (x: Int, y: Int)?

    /// Idempotent; must run before the first TerminalSurfaceView is created.
    /// `colors`: the Hangar theme's terminal colours (see `TerminalColors`); `padding` (pt) is a default
    /// (`window-padding-x/y`) that the user's own value beats.
    public func start(colors: TerminalColors, padding: (x: Int, y: Int)? = nil) throws {
        guard app == nil else { return }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            throw GhosttyError.initFailed
        }
        self.padding = padding
        let cfg = buildConfig(colors)
        var rt = Self.runtimeConfig()
        guard let created = ghostty_app_new(&rt, cfg) else {
            ghostty_config_free(cfg)
            throw GhosttyError.appCreateFailed
        }
        app = created
        config = cfg
        ghostty_app_set_focus(created, NSApp.isActive)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyApp.shared.app.map { ghostty_app_set_focus($0, true) } }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyApp.shared.app.map { ghostty_app_set_focus($0, false) } }
        }
        // Ghostty caches the keymap; it must reload when the layout changes (e.g. EN <-> RU).
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyApp.shared.app.map { ghostty_app_keyboard_changed($0) } }
        }
    }

    /// Theme switch: rebuilds the config with the new colours; terminals opened after it get them (no restart).
    /// shortcut: open surfaces keep their colours — `ghostty_surface_update_config` re-applies the user's Ghostty theme
    /// over Hangar's override (checked live: the background went back to the theme's); revisit with a libghostty update.
    public func update(colors: TerminalColors) {
        guard let app else { return }
        let cfg = buildConfig(colors)
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    /// The user's config with Hangar's files around it; logs its diagnostics.
    private func buildConfig(_ colors: TerminalColors) -> ghostty_config_t? {
        let user = Self.userSets()
        let override = colors.forceBackground
            ? Self.writeConfig(Self.configFileName("overrides"), "background = \(colors.background)\n") : nil
        let text = Self.defaultsConfig(padding: padding, cursor: colors.cursor,
                                       background: user.background ? nil : colors.background,
                                       palette: user.palette ? [] : colors.palette)
        let defaults = text.isEmpty ? nil : Self.writeConfig(Self.configFileName("defaults"), text)
        if override == nil { try? FileManager.default.removeItem(at: Self.tempFile(Self.configFileName("overrides"))) }
        let cfg = Self.makeConfig(defaults: defaults, override: override)
        let bg = override != nil ? "Hangar \(colors.background)" : user.background ? "Ghostty config" : "Hangar default \(colors.background)"
        ghosttyLog.info("terminal background: \(bg, privacy: .public); palette: \(user.palette ? "Ghostty config" : "Hangar", privacy: .public)")
        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            let message = String(cString: ghostty_config_get_diagnostic(cfg, i).message)
            ghosttyLog.warning("config: \(message, privacy: .public)")
        }
        return cfg
    }

    /// Whether the user's Ghostty config (or its `theme`) sets a background / palette: compared with Ghostty's own
    /// defaults. Needed because a `theme` is applied under all loaded files, Hangar's defaults included.
    private static func userSets() -> (background: Bool, palette: Bool) {
        let bare = ghostty_config_new(), user = ghostty_config_new()
        defer { ghostty_config_free(bare); ghostty_config_free(user) }
        ghostty_config_finalize(bare)
        ghostty_config_load_default_files(user)
        ghostty_config_load_recursive_files(user)
        ghostty_config_finalize(user)
        func differs<T>(_ key: String, _ empty: T) -> Bool {
            var a = empty, b = empty
            guard ghostty_config_get(bare, &a, key, UInt(key.utf8.count)),
                  ghostty_config_get(user, &b, key, UInt(key.utf8.count)) else { return false }
            return withUnsafeBytes(of: &a) { pa in withUnsafeBytes(of: &b) { pb in !pa.elementsEqual(pb) } }
        }
        return (differs("background", ghostty_config_color_s()), differs("palette", ghostty_config_palette_s()))
    }

    /// Text of hangar-ghostty-defaults.conf; empty when there is nothing to set.
    /// `background` / `palette` ("rrggbb"): the theme's, left out (nil / empty) where the user's config sets its own.
    public static func defaultsConfig(padding: (x: Int, y: Int)?, cursor: String?, background: String? = nil,
                                      palette: [String] = []) -> String {
        (padding.map { "window-padding-x = \($0.x)\nwindow-padding-y = \($0.y)\n" } ?? "")
            + (cursor.map { "cursor-color = \($0)\n" } ?? "")
            + (background.map { "background = \($0)\n" } ?? "")
            + palette.enumerated().map { "palette = \($0.offset)=#\($0.element)\n" }.joined()
    }

    /// Per process, so a real app and a debug copy don't overwrite each other's file.
    public static func configFileName(_ kind: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String {
        "hangar-ghostty-\(kind)-\(pid).conf"
    }

    /// Removes this process's config files; called on quit.
    public static func removeConfigFiles() {
        for kind in ["defaults", "overrides"] { try? FileManager.default.removeItem(at: tempFile(configFileName(kind))) }
    }

    private static func tempFile(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(name) }

    /// A config file of Hangar's own in the temp directory (never the user's Ghostty config); nil if it can't be written.
    private static func writeConfig(_ name: String, _ text: String) -> URL? {
        let file = tempFile(name)
        return (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil ? file : nil
    }

    /// `defaults` load before the user's files (theirs win), `override` after them (it wins over their config and theme).
    private static func makeConfig(defaults: URL?, override: URL?) -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        if let defaults { defaults.path.withCString { ghostty_config_load_file(cfg, $0) } }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        if let override { override.path.withCString { ghostty_config_load_file(cfg, $0) } }
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// Nonisolated so the C callbacks don't inherit MainActor (Swift would assert the queue; some run on Ghostty's threads).
    nonisolated private static func runtimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                // Any thread; the tick drives all callbacks on main.
                DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyApp.shared.tick() } }
            },
            action_cb: { _, target, action in GhosttyApp.handleAction(target, action) },
            read_clipboard_cb: { ud, location, state in
                nonisolated(unsafe) let (ud, state) = (ud, state)  // raw pointers, used only on main
                return onMain { TerminalSurfaceView.from(ud)?.readClipboard(location, state: state) ?? false } ?? false
            },
            confirm_read_clipboard_cb: { ud, str, state, request in
                guard let str else { return }
                let text = String(cString: str)
                nonisolated(unsafe) let (ud, state) = (ud, state)
                onMain { TerminalSurfaceView.from(ud)?.confirmReadClipboard(text, state: state, request: request) }
            },
            write_clipboard_cb: { _, location, content, len, confirm in
                guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
                // shortcut: only text/plain is written; OSC 52 writes needing confirmation are dropped, add a sheet if asked.
                let text = (0..<len).first { content[$0].mime.map { String(cString: $0) } == "text/plain" }
                    .flatMap { content[$0].data.map { String(cString: $0) } }
                guard let text, !confirm else { return }
                onMain {
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(text, forType: .string)
                }
            },
            close_surface_cb: { _, processAlive in
                // With a command set Ghostty waits after exit; the owner closes the tab, we just log.
                ghosttyLog.debug("close_surface processAlive=\(processAlive)")
            }
        )
    }

    private func tick() {
        if let app { ghostty_app_tick(app) }
    }

    nonisolated private static func handleAction(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return false }
        let ud = ghostty_surface_userdata(surface)
        // Copy C strings now: they only live for the duration of the callback.
        let event: TerminalSurfaceView.Event
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            event = .title(String(cString: action.action.set_title.title))
        case GHOSTTY_ACTION_RING_BELL:
            event = .bell
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            event = .notification(title: String(cString: n.title), body: String(cString: n.body))
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            event = .commandFinished(action.action.command_finished.exit_code)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            event = .childExited  // returning true stops Ghostty printing "Process exited" into the terminal
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            event = .mouseShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            event = .mouseVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_CELL_SIZE:
            event = .cellSize(width: action.action.cell_size.width, height: action.action.cell_size.height)
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return false }
            let s = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(u.len)), as: UTF8.self)
            event = .openURL(s)
        default:
            // Splits/tabs/etc. are host requests we don't implement (our own UI owns layout).
            return false
        }
        return onMain { TerminalSurfaceView.from(ud)?.handle(event) ?? false } ?? false
    }
}

/// Runs inline when already on main (the usual case: callbacks come from ghostty_app_tick),
/// otherwise hops to main asynchronously and returns nil.
@discardableResult
nonisolated func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T? {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    DispatchQueue.main.async { _ = MainActor.assumeIsolated(body) }
    return nil
}
