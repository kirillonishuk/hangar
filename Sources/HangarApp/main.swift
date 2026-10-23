import AppKit
import CoreServices
import os
import ControlServer
import Exec
import GhosttyBridge
import HangarUI
import Workspace

// Before anything reads the environment: every tab inherits it.
for key in inheritedAgentEnvToScrub(ProcessInfo.processInfo.environment) { unsetenv(key) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?
    var appState: AppState?
    var server: ControlServer?
    /// `kill -TERM` (logout of a launchd job, a script): quit through `applicationWillTerminate`, never ask.
    private var sigtermReceived = false
    private var sigterm: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)  // the default action would kill the app before the state is saved
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.sigtermReceived = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        sigterm = source
    }

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
        #if DEBUG
        // Debug runs never touch the real ~/.claude / ~/.codex: overrides, else a throwaway temp copy.
        let env = ProcessInfo.processInfo.environment
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-debug")
        app.claudeSettingsURL = env["HANGAR_CLAUDE_SETTINGS"].map(URL.init(fileURLWithPath:)) ?? scratch.appendingPathComponent("claude/settings.json")
        app.codexConfigURL = env["HANGAR_CODEX_CONFIG"].map(URL.init(fileURLWithPath:)) ?? scratch.appendingPathComponent("codex/config.toml")
        app.findAgentDirs = nil  // CLAUDE_CONFIG_DIR / CODEX_HOME would lead back to real files
        if let ssh = env["HANGAR_SSH"] { app.sshPath = ssh }  // verification runs never dial real hosts
        if let config = env["HANGAR_SSH_CONFIG"] { app.sshConfigPath = config }  // a fixture instead of ~/.ssh/config
        #endif
        let wc = MainWindowController(app: app, configWarning: warning)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        windowController = wc
        wc.enableNotifications()
        appState = app
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appState?.remote.didWake() }
        }
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
        switch wc.currentQuitDecision(forced: isForcedQuit(sigterm: sigtermReceived, reason: reason)) {
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

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.remote.appBecameActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.remote.stopAll()
        server?.stop()
        appState?.keepAwake.stop()
        appState?.saveNow()
        // ghostty_surface_free waits for the child with no timeout: one that ignores SIGHUP would hang quit. State is saved and the server stopped by now.
        Thread.detachNewThread { sleep(3); _exit(0) }
        TerminalSurfaceView.freeAll()  // last: blocks until every tab's child has exited
    }

    /// The socket doubles as the single-instance lock: a live one means another Hangar owns this state dir.
    private func startControlServer(stateDir: URL, socketPath: String) {
        ensurePrivateDirectory(stateDir, tightenExisting: stateDir.standardizedFileURL.path == defaultStateDirectoryPath())
        // Messages that arrive before AppState exists are dropped.
        let server = ControlServer(path: socketPath, handler: { [weak self] in self?.appState?.handle($0) },
                                   onRequest: { [weak self] id, call in
                                       await self?.appState?.respond(id, call)
                                           ?? ControlResponse(id: id, body: .failure(ControlError(code: .failed, message: "Hangar is starting")))
                                   })
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
