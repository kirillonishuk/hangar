#if DEBUG
import AppKit
import Workspace

/// Debug hooks (verification without a screen); not compiled in release.
extension MainWindowController {
    /// HANGAR_DEBUG_PROJECT=<path> adds a project at launch; `dev.hangar.debug` distributed
    /// notifications (object = command) drive the UI for verification without a screen.
    func installDebugHooks() {
        // The hook drives the UI (incl. typing into terminals): only for explicit verification runs.
        guard let path = ProcessInfo.processInfo.environment["HANGAR_DEBUG_PROJECT"] else { return }
        // Empty path: hooks without a project (empty-state checks).
        if !path.isEmpty, !app.state.projects.contains(where: { $0.path == path }) { app.addProject(path: path) }
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.hangar.debug"), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.debugCommand(command) }
        }
    }

    private static func texts(_ v: NSView) -> [String] {
        ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
    }

    private func debugCommand(_ command: String) {
        uiLog.info("debug command: \(command, privacy: .public)")
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let shortcuts: [String: Shortcut] = [
            "newTab": .newTab, "closeTab": .closeTab, "splitRight": .splitRight, "splitDown": .splitDown,
            "prevTask": .prevTask, "nextTask": .nextTask, "toggleSidebar": .toggleSidebar, "toggleInspector": .toggleInspector,
            "rename": .rename, "archiveTask": .archiveTask,
        ]
        switch parts.first ?? "" {
        case "task":
            let fields = arg.split(separator: "|", maxSplits: 1).map(String.init)
            guard let project = app.selectedTask?.projectId ?? app.state.projects.first?.id else { return }
            app.createTask(projectId: project, name: fields[0], firstMessage: fields.count > 1 ? fields[1] : "")
        case "tab": LeafKind(rawValue: arg).map(app.addTab)
        case "key":
            if let sc = shortcuts[arg] { perform(sc) } else if let n = Int(arg) { perform(.tab(n)) }
        case "select": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.select(taskId: app.orderedTasks[n].id) }
        case "type":
            column.terminalArea.focusedLeaf?.surface?.sendText(arg)
            column.terminalArea.focusedLeaf?.surface?.sendEnter()
        case "pin": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.setPinned(app.orderedTasks[n].id, true) }
        case "archive": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.archive(taskId: app.orderedTasks[n].id) }
        case "fold": if let p = app.state.projects.first { app.setCollapsed(projectId: p.id, !p.collapsed) }
        case "project": app.addProject(path: arg)
        case "snap":
            // Chrome snapshot when the screen can't be captured (Metal terminal layers may come out blank).
            let target = arg.contains("settings") ? settings.window : (window?.attachedSheet ?? window)
            guard let view = target?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        case "enter": _ = column.terminalArea.relaunchFocusedIfExited()
        case "action":
            // action <name> task|project|archived|tab <n>
            let f = arg.split(separator: " ").map(String.init)
            guard f.count == 3, let action = Action.allCases.first(where: { "\($0)" == f[0] }), let n = Int(f[2]) else { return }
            let target: ActionTarget? = switch f[1] {
            case "task": app.orderedTasks.indices.contains(n) ? .task(app.orderedTasks[n].id) : nil
            case "archived": app.archivedTasks.indices.contains(n) ? .task(app.archivedTasks[n].id) : nil
            case "project": app.state.projects.indices.contains(n) ? .project(app.state.projects[n].id) : nil
            default: app.selectedTask.flatMap { t in t.tabs.indices.contains(n) ? .tab(task: t.id, tab: t.tabs[n].id) : nil }
            }
            if let target { action.perform(target, ctx) }
        case "post":
            // post <keyCode> [cmd,shift,opt] — through NSApp, so the key monitor sees it like a real key.
            let f = arg.split(separator: " ").map(String.init)
            guard let code = UInt16(f.first ?? ""), let window else { return }
            var mods: NSEvent.ModifierFlags = []
            for m in (f.count > 1 ? f[1] : "").split(separator: ",") {
                mods.insert(["cmd": .command, "shift": .shift, "opt": .option][String(m)] ?? [])
            }
            let chars = code == 36 ? "\r" : code == 53 ? "\u{1b}" : ""
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        case "button":
            // button <title>: clicks it in the attached sheet/alert (posted keys don't reach a sheet window).
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.title == arg { return b }
                return v.subviews.lazy.compactMap(find).first
            }
            if let root = window?.attachedSheet?.contentView, let b = find(root) { b.performClick(nil) }
            uiLog.info("alert text: \((self.window?.attachedSheet?.contentView).map(Self.texts) ?? [], privacy: .public)")
        case "focus": if let n = Int(arg) { column.terminalArea.debugFocus(n) }
        case "clicked":
            // clicked project|task <n>: what a sidebar row click does (F2 target, terminal gives up the keyboard)
            let f = arg.split(separator: " ").map(String.init)
            guard f.count == 2, let n = Int(f[1]) else { return }
            if f[0] == "project", app.state.projects.indices.contains(n) { app.lastClicked = .project(app.state.projects[n].id) }
            if f[0] == "task", app.orderedTasks.indices.contains(n) { app.lastClicked = .task(app.orderedTasks[n].id) }
            ctx.releaseFocus()
        case "activate": NSApp.activate(ignoringOtherApps: true)  // an inactive window drops synthetic first clicks
        case "typeText": ((window?.attachedSheet ?? window)?.firstResponder as? NSTextView)?.insertText(arg, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "mouse":
            // mouse <x> <y> [<x2> <y2>] — window points from the top-left; one point = (double) click, two = drag.
            let v = arg.split(separator: " ").compactMap { Double($0) }
            guard let window, v.count >= 2 else { return }
            let h = window.contentView?.frame.height ?? 0
            var events: [(NSEvent.EventType, Double, Double, Int)] = []
            if v.count >= 4 {
                events.append((.leftMouseDown, v[0], v[1], 1))
                for i in 1...10 { events.append((.leftMouseDragged, v[0] + (v[2] - v[0]) * Double(i) / 10, v[1] + (v[3] - v[1]) * Double(i) / 10, 1)) }
                events.append((.leftMouseUp, v[2], v[3], 1))
            } else {
                for c in 1...(v.count == 3 ? Int(v[2]) : 1) { events += [(.leftMouseDown, v[0], v[1], c), (.leftMouseUp, v[0], v[1], c)] }
            }
            events.append((.mouseMoved, events.last!.1 + 1, events.last!.2 + 1, 0))  // real pointers keep sending moves
            // Spaced out: SwiftUI drops gesture phases delivered within one run-loop turn.
            for (i, ev) in events.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) {
                    if let e = NSEvent.mouseEvent(with: ev.0, location: NSPoint(x: ev.1, y: h - ev.2), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: Int.random(in: 1...Int(Int32.max)), clickCount: ev.3, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)  // queued like real input (tracking loops read the queue)
                    }
                }
            }
        case "sheet": presentNewTask(projectId: nil)
        case "settings": showSettings(nil)
        case "externalDraft": settings.model.externalEditor = arg  // as if typed, without ↩
        case "closeSettings": settings.window?.performClose(nil)
        case "lang":
            if let lang = Language(rawValue: arg) {
                do { try app.setLanguage(lang) } catch { uiLog.error("lang: \(error.localizedDescription, privacy: .public)") }
            }
            uiLog.info("l10n bundle=\(L10n.resources?.bundlePath ?? "-", privacy: .public) language=\(L10n.language.rawValue, privacy: .public) pinned=\(L10n.sectionPinned, privacy: .public) exit=\(L10n.exitedWithCode(3), privacy: .public) menu=\(NSApp.mainMenu?.items.last?.submenu?.title ?? "-", privacy: .public)")
        case "dump":
            let tasks = app.state.tasks.map { t in
                "\(t.name) archived=\(t.archived) pinned=\(t.pinned) order=\(t.order) tabs=\(t.tabs.map { "\(app.tabLabel($0)) leaves=\($0.root.leaves.map { $0.id.uuidString.prefix(4) }) focus=\($0.focusedLeafId.uuidString.prefix(4))" }) active=\(t.activeTabId == nil ? "-" : "set")"
            } + ["projects=\(app.state.projects.map { "\($0.name)@\($0.path)" }) renaming=\(app.renaming.map { "\($0)" } ?? "-") responder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") sheet=\(window?.attachedSheet != nil) active=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false)"]
            uiLog.info("dump selected=\(self.app.selectedTask?.name ?? "-", privacy: .public) sidebar=\(self.app.state.sidebarWidth)/\(self.app.state.sidebarCollapsed) actual=\(self.sidebarItem.viewController.view.frame.width) panes=\(self.split.splitView.subviews.map { Int($0.frame.width) }, privacy: .public) win=\(Int(self.window?.frame.width ?? 0))\n\(tasks.joined(separator: "\n"), privacy: .public)\n\(self.column.terminalArea.debugDump(), privacy: .public)")
        default: break
        }
    }
}
#endif
