#if DEBUG
import AppKit
import Exec
import Git
import SwiftUI
import Usage
import Workspace

/// Off-screen branch list of the open new-task sheet: an inactive app closes real popovers at once, and
/// `NSWindow.sendEvent` reaches the first responder without the app being active.
@MainActor private var pickerWindow: NSWindow?

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

    /// NSPopover's window (e.g. the branch picker), if one is shown.
    private var popoverWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    private static func texts(_ v: NSView) -> [String] {
        ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
    }

    /// Per-leaf agent state and session id, per-task state, usage.
    private func debugAgents() -> [String] {
        var lines: [String] = []
        for t in app.state.tasks where !t.archived {
            for l in t.tabs.flatMap(\.root.leaves) + [t.drawer.leaf].compactMap({ $0 }) {
                let state = app.state(ofLeaf: l.id).rawValue
                let message = app.lastNotificationMessage[l.id] ?? "-"
                lines.append("agent leaf=\(l.id.uuidString) kind=\(l.kind.rawValue) state=\(state) session=\(l.agentSessionId ?? "-") message=\(message)")
            }
            lines.append("agent task=\(t.name) state=\(app.state(of: t).rawValue)")
        }
        let now = app.usageClock
        let windows: [String] = app.usage.view(.claude, now: now)?.windows.map { "\($0.kind)=\(Int($0.usedPercent))" } ?? []
        let level: String = app.usage.level(.claude, now: now).map { "\($0)" } ?? "-"
        lines.append("agents working=\(app.workingLeafCount) usage.claude=\(windows) level=\(level)")
        lines.append("limits rows=\(app.limitRows.map(\.agent.rawValue)) popover=\(app.limitsPopoverShown) codex=\(app.codexRead != nil)")
        return lines
    }

    private static func describe(_ d: DiffState) -> String {
        switch d {
        case .none: "none"
        case .loading: "loading"
        case .notChanged: "notChanged"
        case .failed(let e): "failed(\(e))"
        case .loaded(.text(let hunks, let o, let n)): "text(hunks=\(hunks.count) lines=\(hunks.reduce(0) { $0 + $1.lines.count }) mode=\(o ?? "-")→\(n ?? "-"))"
        case .loaded(let other): "\(other)"
        }
    }

    private func debugCommand(_ command: String) {
        uiLog.info("debug command: \(command, privacy: .public)")
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let shortcuts: [String: Shortcut] = [
            "newTab": .newTab, "closeTab": .closeTab, "splitRight": .splitRight, "splitDown": .splitDown,
            "prevTask": .prevTask, "nextTask": .nextTask, "toggleSidebar": .toggleSidebar, "toggleInspector": .toggleInspector,
            "rename": .rename, "archiveTask": .archiveTask, "toggleDrawer": .toggleDrawer, "limits": .limits,
        ]
        switch parts.first ?? "" {
        case "task":
            let fields = arg.split(separator: "|", maxSplits: 1).map(String.init)
            guard let project = app.selectedTask?.projectId ?? app.state.projects.first?.id else { return }
            app.createTask(projectId: project, name: fields[0], firstMessage: fields.count > 1 ? fields[1] : "", mode: .mainFolder)
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
            let target = arg.contains("integration") ? settings.window?.attachedSheet : arg.contains("settings") ? settings.window : arg.contains("popover") ? popoverWindow : (window?.attachedSheet ?? window)
            guard let view = target?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        case "enter": _ = column.terminalArea.relaunchFocusedIfExited()
        case "open":
            // open <absolute path> [line]: as an inspector click would.
            var path = arg, line: Int?
            if let space = arg.lastIndex(of: " "), let n = Int(arg[arg.index(after: space)...]) { path = String(arg[..<space]); line = n }
            app.openInEditor(path: path, line: line)
        case "screen":
            // screen <file>: the focused terminal's text (incl. scrollback) for checks without a screen.
            try? (column.terminalArea.focusedLeaf?.surface?.screenText() ?? "").write(toFile: arg, atomically: true, encoding: .utf8)
        case "keys":
            // keys <chars>: real key presses into the focused terminal ("␣" = space, "⎋" = Esc).
            guard let surface = column.terminalArea.focusedLeaf?.surface, let w = surface.window else { return }
            // ANSI keycodes (kVK_ANSI_A…): with the kitty keyboard protocol the keycode, not the text, is sent.
            let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
                "j": 38, "k": 40, "n": 45, "m": 46, "␣": 49, "⎋": 53]
            for ch in arg {
                guard let code = codes[ch] else { continue }
                let chars = ch == "␣" ? " " : ch == "⎋" ? "\u{1b}" : String(ch)
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                        type == .keyDown ? surface.keyDown(with: e) : surface.keyUp(with: e)
                    }
                }
            }
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
            // "post popover …" → the open popover's window.
            var f = arg.split(separator: " ").map(String.init)
            let toPopover = f.first == "popover"
            if toPopover { f.removeFirst() }
            guard let code = UInt16(f.first ?? ""), let window = toPopover ? popoverWindow : window else { return }
            var mods: NSEvent.ModifierFlags = []
            for m in (f.count > 1 ? f[1] : "").split(separator: ",") {
                mods.insert(["cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control][String(m)] ?? [])
            }
            let chars = [36: "\r", 53: "\u{1b}", 125: "\u{F701}", 126: "\u{F700}"][Int(code)] ?? ""
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
            // clicked project|task <n>: what a sidebar row click does (F2 target; the terminal keeps the keyboard)
            let f = arg.split(separator: " ").map(String.init)
            guard f.count == 2, let n = Int(f[1]) else { return }
            if f[0] == "project", app.state.projects.indices.contains(n) { app.chromeClicked(.project(app.state.projects[n].id)) }
            if f[0] == "task", app.orderedTasks.indices.contains(n) { app.chromeClicked(.task(app.orderedTasks[n].id)) }
        case "activate": NSApp.activate(ignoringOtherApps: true)  // an inactive window drops synthetic first clicks
        case "typeText": ((popoverWindow ?? window?.attachedSheet ?? window)?.firstResponder as? NSTextView)?.insertText(arg, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "mouse":
            // mouse <x> <y> [<x2> <y2>] — window points from the top-left; one point = (double) click, two = drag.
            // "mouse popover …" → the open popover; otherwise the attached sheet, else the main window.
            let v = arg.split(separator: " ").compactMap { Double($0) }
            guard let window = arg.hasPrefix("popover") ? popoverWindow : (window?.attachedSheet ?? window), v.count >= 2 else { return }
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
        case "hit":
            // hit <x> <y>: the view under a window point (from the top-left) and its frame in window coordinates.
            let v = arg.split(separator: " ").compactMap { Double($0) }
            guard let content = window?.contentView, v.count == 2, let hit = content.hitTest(content.convert(NSPoint(x: v[0], y: content.frame.height - v[1]), from: nil)) else { return }
            uiLog.info("hit \(String(describing: type(of: hit)), privacy: .public) frame=\(String(describing: hit.convert(hit.bounds, to: nil)), privacy: .public)")
        case "sheet":  // sheet [<project index>]
            presentNewTask(projectId: Int(arg).flatMap { app.state.projects.indices.contains($0) ? app.state.projects[$0].id : nil })
        case "settings": showSettings(nil)
        case "externalDraft": settings.model.externalEditor = arg  // as if typed, without ↩
        case "closeSettings": settings.window?.performClose(nil)
        case "integration":
            // integration claude|codex install|remove (opens the consent sheet) | confirm (= «Применить») | cancel | dump
            let f = arg.split(separator: " ").map(String.init)
            let m = settings.model
            switch f.first ?? "" {
            case "claude", "codex": m.review(f[0] == "claude" ? .claude : .codex, install: f.count > 1 && f[1] == "install")
            case "confirm": m.confirmPlan()
            case "cancel": m.cancelPlan()
            default: break
            }
            let i = m.integration
            uiLog.info("integration claude=\(String(describing: i.claude), privacy: .public) codex=\(String(describing: i.codex), privacy: .public) cli=\(i.cli ?? "-", privacy: .public) sheet=\(m.pendingPlan != nil) attached=\(self.settings.window?.attachedSheet != nil) error=\(i.error ?? "-", privacy: .public) message=\(i.message ?? "-", privacy: .public)")
        case "lang":
            if let lang = Language(rawValue: arg) {
                do { try app.setLanguage(lang) } catch { uiLog.error("lang: \(error.localizedDescription, privacy: .public)") }
            }
            uiLog.info("l10n bundle=\(L10n.resources?.bundlePath ?? "-", privacy: .public) language=\(L10n.language.rawValue, privacy: .public) pinned=\(L10n.sectionPinned, privacy: .public) exit=\(L10n.exitedWithCode(3), privacy: .public) menu=\(NSApp.mainMenu?.items.last?.submenu?.title ?? "-", privacy: .public)")
        case "picker":
            // picker open | key <code> | type <text> | snap <path>
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let rest = f.count > 1 ? f[1] : ""
            switch f.first ?? "" {
            case "open":
                guard let model = newTaskModelForDebug else { return }
                let list = BranchList(selection: Binding(get: { model.base }, set: { model.base = $0 }),
                                      branches: model.branches, defaultBase: model.defaultBase,
                                      taskBranches: model.taskBranches, defaultOption: nil) {
                    uiLog.info("picker closed base=\(model.base ?? "-", privacy: .public)")
                }
                let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: Theme.dropdownWidth, height: 340),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: list)
                w.orderFrontRegardless()
                pickerWindow = w
            case "key":
                guard let w = pickerWindow, let code = UInt16(rest) else { return }
                let chars = [36: "\r", 53: "\u{1b}", 125: "\u{F701}", 126: "\u{F700}"][Int(code)] ?? ""
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { w.sendEvent(e) }
            case "type": (pickerWindow?.firstResponder as? NSTextView)?.insertText(rest, replacementRange: NSRange(location: NSNotFound, length: 0))
            case "snap":
                guard let view = pickerWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: rest))
                uiLog.info("picker responder=\(pickerWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-", privacy: .public)")
            default: pickerWindow?.orderOut(nil); pickerWindow = nil  // not close(): last-window-closed quits
            }
        case "ntBranch": newTaskModelForDebug?.branch = arg  // as if typed into «Новая ветка»
        case "windows": uiLog.info("windows: \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) key=\($0.isKeyWindow)" }, privacy: .public)")
        case "inspector":
            // inspector [files|changes|toggleMode|expand <dir>|click <row>]: drives the inspector; logs its rows.
            // With no argument it shows the selected task even when the window is occluded (the watcher stays off).
            let m = app.inspector
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch f.first ?? "" {
            case "files": m.segment = .files
            case "changes": m.segment = .changes
            case "toggleMode": m.toggleMode()
            case "expand": if f.count > 1 { m.expand(f[1]) }
            case "diff": if f.count > 1 { m.loadDiff(path: f[1]) }
            // change <n>: a click on the n-th Changes row (0-based) → the diff tab.
            case "change": if f.count > 1, let n = Int(f[1]), let files = m.changes?.files, files.indices.contains(n) { app.openDiff(path: files[n].path) }
            case "diffTab": app.activateDiff()  // a click on the diff tab
            case "diffRow": if f.count > 1 { app.selectDiffRow(Int(f[1])) }  // a click on a diff row
            case "diffKey":
                // diffKey up|down|enter|optB|cmdW: a real key through the key monitor (as `post`).
                let keys = ["up": "126", "down": "125", "enter": "36", "optB": "11 opt", "cmdW": "13 cmd"]
                if f.count > 1, let key = keys[f[1]] { debugCommand("post " + key) }
            case "":
                if let task = app.selectedTask {
                    let root: String? = if case .worktree(let p, _, _) = task.mode { p } else { app.project(task.projectId)?.path }
                    let app = self.app
                    let runner = app.project(task.projectId).map(app.runner(for:)) ?? .local
                    m.show(taskId: task.id, root: root, git: { Git(repo: $0, runner: runner) }, remote: !runner.isLocal,
                           baseBranch: { await app.baseBranch(of: task) })
                }
            default: break
            }
            uiLog.info("inspector visible=\(self.app.state.inspectorVisible) width=\(self.inspectorItem.viewController.view.frame.width) state=\(self.app.state.inspectorWidth) occlusion=\(self.window?.occlusionState.contains(.visible) ?? false) git=\(m.isGit) root=\(m.root ?? "-", privacy: .public) rows=\(visibleRows(m.tree, expanded: m.expanded).map(\.id), privacy: .public) changes=\(m.changes?.files.map(\.path) ?? [], privacy: .public) mode=\(String(describing: m.changes?.mode), privacy: .public) base=\(m.baseName ?? "-", privacy: .public) error=\(m.error ?? "-", privacy: .public) diffPath=\(m.diffPath ?? "-", privacy: .public) diff=\(Self.describe(m.diff), privacy: .public) diffTab=\(self.app.selectedTask.flatMap { self.app.diffTabs[$0.id] }.map { "\($0.path) active=\($0.active) row=\(self.app.activeDiffSelection.map(String.init) ?? "-")" } ?? "-", privacy: .public) rows=\(self.app.activeDiffContent.rows.count) open=\(self.app.activeDiff.flatMap { _ in openTarget(rows: self.app.activeDiffContent.rows, selected: self.app.activeDiffSelection) }.map(String.init) ?? "-", privacy: .public) responder=\(self.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-", privacy: .public)")
        case "quit": NSApp.terminate(nil)  // runs applicationWillTerminate like ⌘Q
        case "dump":
            let tasks = app.state.tasks.map { t in
                "\(t.name) archived=\(t.archived) pinned=\(t.pinned) order=\(t.order) tabs=\(t.tabs.map { "\(app.tabLabel($0)) leaves=\($0.root.leaves.map { $0.id.uuidString.prefix(4) }) focus=\($0.focusedLeafId.uuidString.prefix(4))" }) active=\(t.activeTabId == nil ? "-" : "set") drawer=\(t.drawer.visible)/\(Int(t.drawer.height))/\(t.drawer.leaf?.id.uuidString.prefix(4) ?? "-")"
            } + debugAgents() + ["projects=\(app.state.projects.map { "\($0.name)@\($0.path)" }) renaming=\(app.renaming.map { "\($0)" } ?? "-") responder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") sheet=\(window?.attachedSheet != nil) active=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false)"]
            uiLog.info("dump selected=\(self.app.selectedTask?.name ?? "-", privacy: .public) sidebar=\(self.app.state.sidebarWidth)/\(self.app.state.sidebarCollapsed) actual=\(self.sidebarItem.viewController.view.frame.width) panes=\(self.split.splitView.subviews.map { Int($0.frame.width) }, privacy: .public) win=\(Int(self.window?.frame.width ?? 0))x\(Int(self.window?.contentView?.frame.height ?? 0))\n\(tasks.joined(separator: "\n"), privacy: .public)\n\(self.column.terminalArea.debugDump(), privacy: .public)")
        default: break
        }
    }
}
#endif
