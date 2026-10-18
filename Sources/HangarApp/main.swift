import AppKit
import GhosttyBridge
import HangarUI
import Workspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let (config, warning) = HangarConfig.load(from: home.appendingPathComponent(".config/hangar/config.toml"))
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
        let app = AppState(state: state, store: store, config: config)
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
                alert.messageText = "Не удалось запустить терминал (Ghostty)"
                alert.informativeText = String(describing: error)
                alert.addButton(withTitle: "Повторить")
                alert.addButton(withTitle: "Выйти")
                if alert.runModal() != .alertFirstButtonReturn { exit(0) }  // user chose to quit
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quit plus a standard Edit menu, so text fields (new-task sheet, rename) get copy/paste/undo.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Скрыть Hangar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти из Hangar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
