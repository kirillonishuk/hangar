import AppKit
import CoreServices
import os
import ControlServer
import GhosttyBridge
import HangarUI
import Workspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?
    var appState: AppState?
    var server: ControlServer?

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

        let stateDir: URL = {
            #if DEBUG
            // Verification runs must not touch the real state file.
            if let dir = ProcessInfo.processInfo.environment["HANGAR_STATE_DIR"] { return URL(fileURLWithPath: dir) }
            #endif
            return home.appendingPathComponent("Library/Application Support/Hangar")
        }()
        let socketPath = stateDir.appendingPathComponent("hangar.sock").path
        startControlServer(stateDir: stateDir, socketPath: socketPath)
        startGhostty(background: config.terminalBackground == .hangar ? Theme.terminalBackgroundHex : nil)

        let store = StateStore(directory: stateDir)
        let result = store.load()
        let state: WorkspaceState
        if case .loaded(let loaded) = result { state = loaded } else { state = WorkspaceState() }
        let app = AppState(state: state, store: store, config: config, configURL: configURL, socketPath: socketPath)
        let wc = MainWindowController(app: app, configWarning: warning)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        windowController = wc
        wc.enableNotifications()
        appState = app
        if activateAllowed { NSApp.activate(ignoringOtherApps: true) }
        if let text = loadAlert(for: result), let window = wc.window {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = text
            alert.addButton(withTitle: L10n.ok)
            alert.beginSheetModal(for: window)
        }
    }

    private var activateAllowed: Bool {
        #if DEBUG
        // Verification runs next to the user's work: don't steal focus.
        return ProcessInfo.processInfo.environment["HANGAR_DEBUG_NO_ACTIVATE"] == nil
        #else
        return true
        #endif
    }

    /// A worktree being created would be left half-done: refuse to quit until git finishes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let wc = windowController else { return .terminateNow }
        // 0x7768793F = keyAEQuitReason ('why?')
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(0x7768793F))?.enumCodeValue
        switch wc.currentQuitDecision(systemShutdown: isSystemShutdown(reason: reason)) {
        case .terminateNow: return .terminateNow
        case .cancelCreating:
            wc.notifyCreatingTask()
            return .terminateCancel
        // A repeated ⌘Q while the sheet is up must not open a second one nor reply twice.
        case .alreadyAsking: return .terminateCancel
        case .ask:
            wc.confirmQuit { NSApp.reply(toApplicationShouldTerminate: $0) }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        appState?.saveNow()
    }

    /// The socket doubles as the single-instance lock: a live one means another Hangar owns this state dir.
    private func startControlServer(stateDir: URL, socketPath: String) {
        ensurePrivateDirectory(stateDir, tightenExisting: stateDir.standardizedFileURL.path == defaultStateDirectoryPath())
        // Messages that arrive before AppState exists are dropped.
        let server = ControlServer(path: socketPath) { [weak self] in self?.appState?.handle($0) }
        do {
            try server.start()
            self.server = server
        } catch .alreadyRunning(let pid) {
            if activateAllowed { NSRunningApplication(processIdentifier: pid)?.activate() }
            exit(0)
        } catch {
            // Without the socket hooks can't reach the app; terminals and fallbacks still work.
            uiLog.error("control socket failed: \(String(describing: error), privacy: .public)")
        }
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

// A write to a dead child's pipe must not kill the app.
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
