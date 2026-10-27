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
        guard Self.initialized else { throw GhosttyError.initFailed }
        self.padding = padding
        let cfg = Self.buildConfig(colors, padding: padding)
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

    /// `ghostty_init` once per process (the app and tests that build configs).
    static let initialized = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS

    /// Theme / «Фон терминала» switch: rebuilds the config; `ghostty_app_update_config` hands it to every open surface,
    /// which replays the same layers, so open terminals recolor too (decision #87; checked live with a user `theme`).
    public func update(colors: TerminalColors) {
        guard let app else { return }
        let cfg = Self.buildConfig(colors, padding: padding)
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    /// The user's config with Hangar's files around it; logs its diagnostics.
    /// `userFiles`: instead of the user's default Ghostty files (tests); nil = theirs.
    static func buildConfig(_ colors: TerminalColors, padding: (x: Int, y: Int)?, userFiles: [URL]? = nil) -> ghostty_config_t? {
        let user = userSets(userFiles)
        let layers = layers(colors, padding: padding, userBackground: user.background, userPalette: user.palette)
        let defaults = layers.defaults.isEmpty ? nil : writeConfig(configFileName("defaults"), layers.defaults)
        let overridesFile = tempFile(configFileName("overrides"))
        var override: URL?
        if let text = layers.overrides {
            override = writeConfig(configFileName("overrides"), text)
            // A failed write keeps the previous overrides (the last theme's background) rather than dropping them.
            if override == nil, FileManager.default.fileExists(atPath: overridesFile.path) {
                ghosttyLog.error("terminal background: keeping the previous \(overridesFile.path, privacy: .public)")
                override = overridesFile
            }
        } else {
            try? FileManager.default.removeItem(at: overridesFile)
        }
        let cfg = makeConfig(defaults: defaults, override: override, userFiles: userFiles)
        let bg = override != nil ? "Hangar \(colors.background)" : user.background ? "Ghostty config" : "Hangar default \(colors.background)"
        ghosttyLog.info("terminal background: \(bg, privacy: .public); palette: \(user.palette ? "Ghostty config" : "Hangar", privacy: .public)")
        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            let message = String(cString: ghostty_config_get_diagnostic(cfg, i).message)
            ghosttyLog.warning("config: \(message, privacy: .public)")
        }
        return cfg
    }

    /// Hangar's two files: `defaults` (before the user's files, theirs win) and `overrides` (after them, nil = none).
    /// The background goes to `overrides` when forced («как тема»), else to `defaults` unless the user sets one.
    static func layers(_ colors: TerminalColors, padding: (x: Int, y: Int)?, userBackground: Bool,
                       userPalette: Bool) -> (defaults: String, overrides: String?) {
        let defaults = defaultsConfig(padding: padding, cursor: colors.cursor,
                                      background: userBackground || colors.forceBackground ? nil : colors.background,
                                      palette: userPalette ? [] : colors.palette)
        return (defaults, colors.forceBackground ? "background = \(colors.background)\n" : nil)
    }

    /// Whether the user's Ghostty config (or its `theme`) sets a background / palette: compared with Ghostty's own
    /// defaults. Needed because a `theme` is applied under all loaded files, Hangar's defaults included.
    static func userSets(_ userFiles: [URL]? = nil) -> (background: Bool, palette: Bool) {
        let bare = ghostty_config_new(), user = ghostty_config_new()
        defer { ghostty_config_free(bare); ghostty_config_free(user) }
        ghostty_config_finalize(bare)
        loadUserFiles(user, userFiles)
        ghostty_config_finalize(user)
        func differs<T>(_ key: String, _ empty: T) -> Bool {
            var a = empty, b = empty
            guard ghostty_config_get(bare, &a, key, UInt(key.utf8.count)),
                  ghostty_config_get(user, &b, key, UInt(key.utf8.count)) else { return false }
            return withUnsafeBytes(of: &a) { pa in withUnsafeBytes(of: &b) { pb in !pa.elementsEqual(pb) } }
        }
        return (differs("background", ghostty_config_color_s()), differs("palette", ghostty_config_palette_s()))
    }

    private static func loadUserFiles(_ cfg: ghostty_config_t?, _ files: [URL]?) {
        guard let files else {
            ghostty_config_load_default_files(cfg)
            ghostty_config_load_recursive_files(cfg)
            return
        }
        for file in files { file.path.withCString { ghostty_config_load_file(cfg, $0) } }
        ghostty_config_load_recursive_files(cfg)
    }

    /// The `background` ("rrggbb") a config built from these layers ends up with (tests).
    static func resolvedBackground(_ colors: TerminalColors, userFiles: [URL]) -> String? {
        let cfg = buildConfig(colors, padding: nil, userFiles: userFiles)
        defer { ghostty_config_free(cfg) }
        var c = ghostty_config_color_s(), key = "background"
        guard ghostty_config_get(cfg, &c, key, UInt(key.utf8.count)) else { return nil }
        return String(format: "%02x%02x%02x", c.r, c.g, c.b)
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
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            ghosttyLog.error("can't write \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `defaults` load before the user's files (theirs win), `override` after them (it wins over their config and theme).
    private static func makeConfig(defaults: URL?, override: URL?, userFiles: [URL]?) -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        if let defaults { defaults.path.withCString { ghostty_config_load_file(cfg, $0) } }
        loadUserFiles(cfg, userFiles)
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
