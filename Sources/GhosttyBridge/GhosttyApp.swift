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

    /// Idempotent; must run before the first TerminalSurfaceView is created.
    /// `defaultBackground` ("rrggbb") is used only when the user's Ghostty config doesn't change the background.
    public func start(defaultBackground: String? = nil) throws {
        guard app == nil else { return }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            throw GhosttyError.initFailed
        }
        var cfg = Self.makeConfig(layeredUnder: nil)
        if let hex = defaultBackground {
            let pristine = ghostty_config_new()
            ghostty_config_finalize(pristine)
            // Same as Ghostty's built-in default → the user (config or theme) didn't set one.
            let userSetsBackground = Self.background(cfg) != Self.background(pristine)
            ghosttyLog.info("terminal background: \(userSetsBackground ? "user's Ghostty config" : "Hangar default", privacy: .public)")
            if !userSetsBackground {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-ghostty-defaults.conf")
                if (try? "background = \(hex)\n".write(to: file, atomically: true, encoding: .utf8)) != nil {
                    ghostty_config_free(cfg)
                    cfg = Self.makeConfig(layeredUnder: file)
                }
            }
            ghostty_config_free(pristine)
        }
        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            let message = String(cString: ghostty_config_get_diagnostic(cfg, i).message)
            ghosttyLog.warning("config: \(message, privacy: .public)")
        }

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

    /// Our defaults load first so every user file loaded after them wins.
    private static func makeConfig(layeredUnder defaults: URL?) -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        if let defaults { defaults.path.withCString { ghostty_config_load_file(cfg, $0) } }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        return cfg
    }

    private static func background(_ cfg: ghostty_config_t?) -> [UInt8] {
        var c = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(cfg, &c, key, UInt(key.utf8.count)) else { return [] }
        return [c.r, c.g, c.b]
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
