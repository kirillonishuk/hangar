import AppKit
import GhosttyBridge
import HangarUI
import Workspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL: URL = {
            #if DEBUG
            // Verification runs must not touch the real config file.
            if let path = ProcessInfo.processInfo.environment["HANGAR_CONFIG"] { return URL(fileURLWithPath: path) }
            #endif
            return home.appendingPathComponent(".config/hangar/config.toml")
        }()
        let (config, warning) = HangarConfig.load(from: configURL)
        L10n.language = config.language  // the Ghostty alert below is already localized
        startGhostty(background: config.terminalBackground == .hangar ? Theme.terminalBackgroundHex : nil)

        let stateDir: URL = {
            #if DEBUG
            // Verification runs must not touch the real state file.
            if let dir = ProcessInfo.processInfo.environment["HANGAR_STATE_DIR"] { return URL(fileURLWithPath: dir) }
            #endif
            return home.appendingPathComponent("Library/Application Support/Hangar")
        }()
        let store = StateStore(directory: stateDir)
        // shortcut: only `.loaded` is used here; corrupt/unreadable handling and restore UX are Task 7
        let state: WorkspaceState
        if case .loaded(let loaded) = store.load() { state = loaded } else { state = WorkspaceState() }
        let app = AppState(state: state, store: store, config: config, configURL: configURL)
        let wc = MainWindowController(app: app, configWarning: warning)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Without Ghostty every terminal would be blank: ask to retry or quit instead of continuing silently.
    private func startGhostty(background: String?) {
        while true {
            do {
                try GhosttyApp.shared.start(background: background)
                return
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = L10n.ghosttyFailed
                alert.informativeText = String(describing: error)
                alert.addButton(withTitle: L10n.retry)
                alert.addButton(withTitle: L10n.quit)
                if alert.runModal() != .alertFirstButtonReturn { exit(0) }  // user chose to quit
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
