#if DEBUG
import AppKit
import Exec
import Git
import History
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
        park(window)
        // HANGAR_DEBUG_CHANNEL scopes the hook, so parallel debug instances don't run each other's commands.
        let channel = ProcessInfo.processInfo.environment["HANGAR_DEBUG_CHANNEL"].map { ".\($0)" } ?? ""
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.hangar.debug" + channel), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.debugCommand(command) }
        }
    }

    /// HANGAR_DEBUG_BEHIND=1: windows stay behind all others, so verification runs don't cover the owner's screen
    /// (captures by window id and `snap` still work; occluded terminals pause rendering).
    private func park(_ w: NSWindow?) {
        guard ProcessInfo.processInfo.environment["HANGAR_DEBUG_BEHIND"] == "1" else { return }
        w?.orderBack(nil)
    }

    static func scrollView(_ v: NSView) -> NSScrollView? {
        (v as? NSScrollView) ?? v.subviews.lazy.compactMap(scrollView).first
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
                let message = app.statuses.status(l.id).attention?.text ?? "-"
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

    /// Indices are in the selected session: `merge <srcTab#> <dstTab#> <leaf#> <edge>`, `moveLeaf <leaf#> <dstTab#> <anchor#> <edge>`
    /// (a leaf of the active tab), `detach <leaf#> [<index>]` (a leaf of the active tab).
    private func debugMove(_ command: String, _ f: [String]) {
        guard let task = app.selectedTask else { return }
        let n = f.map { Int($0) }
        func tab(_ i: Int?) -> Workspace.Tab? { i.flatMap { task.tabs.indices.contains($0) ? task.tabs[$0] : nil } }
        func leaf(_ t: Workspace.Tab?, _ i: Int?) -> UUID? { t.flatMap { t in i.flatMap { t.root.leaves.indices.contains($0) ? t.root.leaves[$0].id : nil } } }
        let active = task.tabs.first { $0.id == task.activeTabId }
        let edge = f.count == 4 ? SplitEdge(rawValue: f[3]) : nil
        switch command {
        case "merge":
            guard let edge, let src = tab(n[0]), let dst = tab(n[1]), let at = leaf(dst, n[2]) else { return }
            app.mergeTab(src.id, into: dst.id, at: at, edge: edge)
        case "moveLeaf":
            guard let edge, let id = leaf(active, n[0]), let dst = tab(n[1]), let anchor = leaf(dst, n[2]) else { return }
            app.moveLeaf(id, to: dst.id, at: anchor, edge: edge)
        default:
            guard let id = leaf(active, n.first ?? nil) else { return }
            app.detachLeaf(id, toIndex: n.count > 1 ? n[1] : nil)
        }
    }

    /// Pane `n` of the active tab (`hover|menu|clicked|action … leaf <n>`).
    private func debugLeafTarget(_ n: Int) -> ActionTarget? {
        guard let task = app.selectedTask, let tab = task.tabs.first(where: { $0.id == task.activeTabId }),
              tab.root.leaves.indices.contains(n) else { return nil }
        return .leaf(task: task.id, tab: tab.id, leaf: tab.root.leaves[n].id)
    }

    private func debugCommand(_ command: String) {
        uiLog.info("debug command: \(command, privacy: .public)")
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let shortcuts: [String: Shortcut] = [
            "newTab": .newTab, "closeTab": .closeTab, "splitRight": .splitRight, "splitDown": .splitDown,
            "prevTask": .prevTask, "nextTask": .nextTask, "toggleSidebar": .toggleSidebar, "toggleInspector": .toggleInspector,
            "rename": .rename, "archiveTask": .archiveTask, "toggleDrawer": .toggleDrawer, "limits": .limits,
            "prevTab": .prevTab, "nextTab": .nextTab, "focusLeft": .focusSplit(.left), "focusRight": .focusSplit(.right),
            "focusUp": .focusSplit(.up), "focusDown": .focusSplit(.down), "inspectorFiles": .inspectorFiles,
            "inspectorChanges": .inspectorChanges, "inspectorGit": .inspectorGit, "revealInFinder": .revealInFinder, "copyPath": .copyPath,
            "quickOpen": .quickOpen, "commandPalette": .commandPalette, "sessions": .sessions, "findInFiles": .findInFiles,
            "nextAttention": .nextAttention,
        ]
        switch parts.first ?? "" {
        case "task":
            let fields = arg.split(separator: "|", maxSplits: 1).map(String.init)
            guard let project = app.selectedTask?.projectId ?? app.state.projects.first?.id else { return }
            app.createTask(projectId: project, name: fields[0], firstMessage: fields.count > 1 ? fields[1] : "", mode: .mainFolder)
        case "ptask":  // ptask <project index> <name>: a main-folder session of that project (e.g. a remote one)
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let n = Int(f[0]), app.state.projects.indices.contains(n) else { return }
            app.createTask(projectId: app.state.projects[n].id, name: f[1], firstMessage: "", mode: .mainFolder)
        case "wtask":
            // wtask <name> <existing worktree path> <branch> <base>: a worktree session over a worktree made beforehand.
            let f = arg.split(separator: " ").map(String.init)
            guard f.count == 4, let project = app.state.projects.first?.id else { return }
            app.createTask(projectId: project, name: f[0], firstMessage: "", mode: .worktree(path: f[1], branch: f[2], base: f[3]))
        case "tab": LeafKind(rawValue: arg).flatMap { $0 == .choose ? nil : $0 }.map(app.addTab)
        // choose <kind>: the focused chooser pane's button; continue <n>: row n of «Продолжить» (chooser or empty session).
        case "choose":
            guard let leaf = column.terminalArea.focusedLeaf, leaf.chooser != nil, let kind = LeafKind(rawValue: arg) else { return }
            if kind == .editor { app.onChooseEditor?(leaf.leafId) } else { app.chooseKind(leaf.leafId, kind) }
        case "chooseFile":  // chooseFile <absolute path>: the chooser's ⌘P pick (an inactive app's palette loses key at once)
            guard let leaf = column.terminalArea.focusedLeaf, leaf.chooser != nil else { return }
            app.chooseEditor(leaf.leafId, path: arg)
        case "continue":
            guard let task = app.selectedTask, let n = Int(arg) else { return }
            let rows = app.recent(for: task.id)
            guard rows.indices.contains(n) else { return }
            if let leaf = column.terminalArea.focusedLeaf, leaf.chooser != nil { app.chooseConversation(leaf.leafId, rows[n]) }
            else if app.showsNoTabs { app.openConversation(rows[n]) }
        case "key":
            if let sc = shortcuts[arg] { perform(sc) } else if let n = Int(arg) { perform(.tab(n)) }
        case "select": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.select(taskId: app.orderedTasks[n].id) }
        case "type":
            column.terminalArea.focusedLeaf?.surface?.sendText(arg)
            column.terminalArea.focusedLeaf?.surface?.sendEnter()
        case "pin": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.setPinned(app.orderedTasks[n].id, true) }
        // search <text>: the Search tab's query (#91); searchToggle case|word|regex.
        case "search": app.search.text = arg
        case "searchExclude": app.search.exclude = arg
        case "searchToggle":
            switch arg {
            case "case": app.search.caseSensitive.toggle()
            case "word": app.search.wholeWord.toggle()
            case "regex": app.search.regex.toggle()
            case "filters": app.search.filtersShown.toggle()  // the «…» include / exclude toggle
            default: break
            }
        // «Сессии»: the search text; the n-th project.
        case "sessionsQuery": column.sessionsModel.query = arg
        case "sessionsClick":  // sessionsClick <n>: as a click on the n-th row of «Сессии» (its main action)
            let m = column.sessionsModel
            let rows = m.visibleList
            if let n = Int(arg), rows.indices.contains(n) { Task { await m.perform(m.primaryAction(rows[n]), ctx: ctx) } }
        case "sessionsHover":  // sessionsHover <n> | -1: the n-th row drawn as hovered (snapshots can't hover)
            let rows = column.sessionsModel.visibleList
            column.sessionsModel.hovered = Int(arg).flatMap { rows.indices.contains($0) ? rows[$0].id : nil }
        case "sessionsScope":  // sessionsScope all | local | <host>
            app.showSessionsView(scope: arg == "all" ? .all : arg == "local" ? .local : .host(arg))
        case "sessionsChip":  // sessionsChip claude | codex | open | archived | history: toggles that chip
            let m = column.sessionsModel
            switch arg {
            case "claude": m.toggle(HistoryAgent.claude)
            case "codex": m.toggle(HistoryAgent.codex)
            case "open": m.toggle(SessionsRowState.open)
            case "archived": m.toggle(SessionsRowState.archived)
            case "history": m.toggle(SessionsRowState.history)
            default: m.resetFilters()
            }
        case "sessionsProject": if let n = Int(arg), app.state.projects.indices.contains(n) { app.showSessionsView(projectId: app.state.projects[n].id) }
        case "archive": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.archive(taskId: app.orderedTasks[n].id) }
        case "fold": if let p = app.state.projects.first { app.setCollapsed(projectId: p.id, !p.collapsed) }
        case "hover", "menu":
            // hover task|project <n> | hover none: the sidebar row drawn as hovered (snapshots can't hover).
            // menu task|project <n>: its «⋯» menu, 200/120 pt into the window.
            let f = arg.split(separator: " ").map(String.init)
            if parts[0] == "hover", f.first == "new" || f.first == "sessions" { app.debugHoverRow = f.first; return }  // hover new|sessions
            if parts[0] == "hover" { app.debugHoverRow = nil }
            let n = f.count > 1 ? Int(f[1]) ?? -1 : -1
            let target: ActionTarget? = switch f.first {
            case "task": app.orderedTasks.indices.contains(n) ? .task(app.orderedTasks[n].id) : nil
            case "project": app.state.projects.indices.contains(n) ? .project(app.state.projects[n].id) : nil
            case "leaf": debugLeafTarget(n)
            default: nil
            }
            if parts[0] == "hover" {
                app.debugHover = target
            } else if let target, let frame = window?.frame {
                PopoverMenu.show(actionMenu(for: target, ctx: ctx), at: NSPoint(x: frame.minX + 200, y: frame.maxY - 120))
            }
        case "project": app.addProject(path: arg)
        case "link": if let url = URL(string: arg) { openLink(url) }  // link <url>: as a clicked hangar:// link (#88)
        case "snap":
            // Chrome snapshot when the screen can't be captured (Metal terminal layers may come out blank).
            let target = arg.contains("integration") ? settings.window?.attachedSheet : arg.contains("settings") ? settings.window : arg.contains("popover") ? popoverWindow : (window?.attachedSheet ?? window)
            // "…-window…": the whole frame view, with the traffic lights.
            guard let view = arg.contains("-window") ? target?.contentView?.superview : target?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        case "lights":  // lights <file>: traffic light frames (window coordinates, bottom-left origin)
            let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { self.window?.standardWindowButton($0) }.map { $0.convert($0.bounds, to: nil) }
            try? "lights \(frames) content=\(String(describing: self.window?.contentView?.frame))".write(toFile: arg, atomically: true, encoding: .utf8)
        case "git": debugGit(arg)
        case "enter": _ = column.terminalArea.relaunchFocusedIfExited()
        case "peek": app.openInEditor(path: arg, line: nil, preview: true)  // peek <absolute path>: a one-click Files open
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
            case "leaf": debugLeafTarget(n)
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
        case "keyEquiv":
            // keyEquiv <keyCode> [cmd,shift,opt]: AppKit's key-equivalent path with the focused terminal as first responder
            // (key monitor → window → main menu); posted keys skip it while the app is inactive. Who took it → $TMPDIR/hangar-keyEquiv.txt.
            let f = arg.split(separator: " ").map(String.init)
            guard let code = UInt16(f.first ?? ""), let window else { return }
            var mods: NSEvent.ModifierFlags = []
            for m in (f.count > 1 ? f[1] : "").split(separator: ",") {
                mods.insert(["cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control][String(m)] ?? [])
            }
            column.terminalArea.debugFocus(0)
            column.terminalArea.focusedLeaf?.surface?.debugFocus()
            let chars = [12: "q", 13: "w"][Int(code)] ?? ""
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            let state = "key=\(window.isKeyWindow) responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-")"
            let by = handleKeyDown(e) ? "monitor" : window.performKeyEquivalent(with: e) ? "window" : "menu"
            try? "keyEquiv \(code) \(state) taken by \(by)\n".write(toFile: NSTemporaryDirectory() + "hangar-keyEquiv.txt", atomically: true, encoding: .utf8)
            if by == "menu" { _ = NSApp.mainMenu?.performKeyEquivalent(with: e) }
        case "button":
            // button <title>: clicks it in the attached sheet/alert (posted keys don't reach a sheet window).
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.title == arg { return b }
                return v.subviews.lazy.compactMap(find).first
            }
            if let root = window?.attachedSheet?.contentView, let b = find(root) { b.performClick(nil) }
            uiLog.info("alert text: \((self.window?.attachedSheet?.contentView).map(Self.texts) ?? [], privacy: .public)")
        case "focus": if let n = Int(arg) { column.terminalArea.debugFocus(n) }
        // commitRename <text>: ↩ in the open inline rename field (an inactive window's field never takes the typing).
        // The field goes first (it saves its own unchanged text on disappear), then the typed name lands.
        case "commitRename":
            guard let target = app.renaming else { return }
            app.cancelRename()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.app.commitRename(target, arg) }
        case "clicked":
            // clicked project|task <n>: what a sidebar row click does (F2 target; the terminal keeps the keyboard)
            let f = arg.split(separator: " ").map(String.init)
            guard f.count == 2, let n = Int(f[1]) else { return }
            if f[0] == "project", app.state.projects.indices.contains(n) { app.chromeClicked(.project(app.state.projects[n].id)) }
            if f[0] == "task", app.orderedTasks.indices.contains(n) { app.chromeClicked(.task(app.orderedTasks[n].id)) }
            if f[0] == "leaf", let target = debugLeafTarget(n) { app.chromeClicked(target) }
        case "activate": NSApp.activate(ignoringOtherApps: true)  // an inactive window drops synthetic first clicks
        case "typeText": ((popoverWindow ?? window?.attachedSheet ?? window)?.firstResponder as? NSTextView)?.insertText(arg, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "mouse":
            // mouse <x> <y> [<x2> <y2> [hold]] — window points from the top-left; one point = (double) click, two = drag;
            // "hold" keeps the button down at the end (then `key esc` / `mouseUp <x> <y>`).
            // "mouse popover …" → the open popover; otherwise the attached sheet, else the main window.
            let v = arg.split(separator: " ").compactMap { Double($0) }
            let hold = arg.hasSuffix(" hold")
            guard let window = arg.hasPrefix("popover") ? popoverWindow : (window?.attachedSheet ?? window), v.count >= 2 else { return }
            let h = window.contentView?.frame.height ?? 0
            var events: [(NSEvent.EventType, Double, Double, Int)] = []
            if v.count >= 4 {
                events.append((.leftMouseDown, v[0], v[1], 1))
                for i in 1...10 { events.append((.leftMouseDragged, v[0] + (v[2] - v[0]) * Double(i) / 10, v[1] + (v[3] - v[1]) * Double(i) / 10, 1)) }
                if !hold { events.append((.leftMouseUp, v[2], v[3], 1)) }
            } else if arg.hasPrefix("up ") {
                events.append((.leftMouseUp, v[0], v[1], 1))
            } else {
                for c in 1...(v.count == 3 ? Int(v[2]) : 1) { events += [(.leftMouseDown, v[0], v[1], c), (.leftMouseUp, v[0], v[1], c)] }
            }
            if !hold { events.append((.mouseMoved, events.last!.1 + 1, events.last!.2 + 1, 0)) }  // real pointers keep sending moves
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
        case "tdrag":
            // tdrag <tab index> <dx> <x> <y> | tdrag <tab index> end: through the tab strip (gap, pane drop mode, controller).
            let f = arg.split(separator: " ").map(String.init)
            guard let n = Int(f.first ?? ""), let tabs = app.selectedTask?.tabs, tabs.indices.contains(n) else { return }
            let v = f.dropFirst().compactMap { Double($0) }
            if f.last == "end" { app.debugTabDrag?(tabs[n].id, 0, nil) } else if v.count == 3 {
                app.debugTabDrag?(tabs[n].id, v[0], CGPoint(x: v[1], y: v[2]))
            }
            try? "closedHand=\(NSCursor.current == NSCursor.closedHand) dragActive=\(paneDrag?.active == true)\n"
                .write(toFile: NSTemporaryDirectory() + "hangar-tdrag.txt", atomically: true, encoding: .utf8)
        case "pdrag", "pdragEnd", "hdrag", "hdragEnd":
            // pdrag <tab index> <x> <y> [<x> <y> …] [end]: tab n dragged through those window points (from the top-left)
            // as the tab strip reports it to `PaneDragController` (an inactive window drops synthetic clicks); pdragEnd <n>: release.
            // hdrag / hdragEnd <pane index>: the same for the header of the active tab's pane n.
            let f = arg.split(separator: " ").map(String.init)
            let header = parts.first?.hasPrefix("h") == true
            guard let n = Int(f.first ?? ""), let task = app.selectedTask else { return }
            let ids = header ? task.tabs.first { $0.id == task.activeTabId }?.root.leaves.map(\.id) ?? [] : task.tabs.map(\.id)
            guard ids.indices.contains(n) else { return }
            let source = header ? PaneDragSource.leaf(ids[n]) : .tab(ids[n])
            let v = f.dropFirst().compactMap { Double($0) }
            var moves: [String] = []
            for i in stride(from: 0, to: v.count - 1, by: 2) {
                moves.append("\(app.paneDragMoved?(source, CGPoint(x: v[i], y: v[i + 1])) ?? false)")
            }
            let ended = parts.first?.hasSuffix("End") == true || f.last == "end" ? "\(app.paneDragEnded?(source) ?? false)" : "-"
            let frames = task.tabs.compactMap { app.tabFrames[$0.id].map { "\(Int($0.minX))-\(Int($0.maxX))" } }
            try? "moved=\(moves) ended=\(ended) target=\(String(describing: app.paneDropTarget)) tabs=\(frames)\n"
                .write(toFile: NSTemporaryDirectory() + "hangar-pdrag.txt", atomically: true, encoding: .utf8)
        case "hit":
            // hit <x> <y>: the view under a window point (from the top-left) and its frame in window coordinates.
            let v = arg.split(separator: " ").compactMap { Double($0) }
            guard let content = window?.contentView, v.count == 2, let hit = content.hitTest(content.convert(NSPoint(x: v[0], y: content.frame.height - v[1]), from: nil)) else { return }
            uiLog.info("hit \(String(describing: type(of: hit)), privacy: .public) frame=\(String(describing: hit.convert(hit.bounds, to: nil)), privacy: .public)")
        case "connectHost": presentConnectHost()
        case "update":  // update check|show|install|later|dump <file>: the in-app updater (#86) against HANGAR_UPDATE_FEED
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch f.first ?? "" {
            case "check": app.updates.checkNow()
            case "show": presentUpdate()
            case "install": app.updates.install()
            case "later": app.updates.later()
            case "dump" where f.count > 1:
                let u = app.updates
                let text = "phase=\(u.phase) current=\(u.current ?? "nil") offer=\(u.offer?.version ?? "nil") pill=\(u.pill?.version ?? "nil") skipped=\(u.record.skipped ?? "nil") error=\(u.installError ?? "nil")\n"
                try? text.write(toFile: f[1], atomically: true, encoding: .utf8)
            default: break
            }
        case "sheet":  // sheet [<project index>]
            presentNewTask(projectId: Int(arg).flatMap { app.state.projects.indices.contains($0) ? app.state.projects[$0].id : nil })
        case "settings":  // settings [general|appearance|editor|notifications|integrations|advanced]
            showSettings(nil)
            if let category = SettingsCategory(rawValue: arg) { settings.model.category = category }
            park(settings.window)
        case "settingsSize":  // settingsSize min|default|<w> <h>: the settings window's frame size
            let a = arg.split(separator: " ").compactMap { Double($0) }
            let size = arg == "min" ? Theme.settingsMinSize : arg == "default" ? Theme.settingsSize
                : a.count == 2 ? NSSize(width: a[0], height: a[1]) : nil
            if let size, let w = settings.window {
                if arg == "default" { w.setContentSize(size) } else { w.setFrame(NSRect(origin: w.frame.origin, size: size), display: true) }
            }
        case "settingsScroll":  // settingsScroll <y>|bottom: the page's scroll position
            if let scroll = settings.window?.contentView.flatMap(Self.scrollView), let doc = scroll.documentView {
                let max = doc.frame.height - scroll.contentView.bounds.height
                let y = arg == "bottom" ? max : min(max, Double(arg) ?? 0)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : max - y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        case "settingsFit":  // settingsFit <file>: the window, the page's scroll width and the content's minimum width
            if let w = settings.window, let host = w.contentViewController as? NSHostingController<SettingsView> {
                let scroll = w.contentView.flatMap(Self.scrollView)
                let fit = host.sizeThatFits(in: NSSize(width: 1, height: 100_000))
                let text = "frame=\(w.frame.size) content=\(w.contentView?.frame.size ?? .zero) minWidth=\(fit.width)"
                    + " clip=\(scroll?.contentView.bounds.size ?? .zero) doc=\(scroll?.documentView?.frame.size ?? .zero)"
                    + " hscroll=\(scroll?.hasHorizontalScroller ?? false)\n"
                try? text.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "edtheme":  // edtheme sample <typescript|json|diff> | hover <id|-> | color <id> [preview] | close | set <id> <hex> | palette <name> | expand <syntax|editor|diff> | confirm | reset [id]
            let a = arg.split(separator: " ").map(String.init)
            let ed = settings.model.editorTheme
            let color = a.count > 1 ? EditorColor(rawValue: a[1]) : nil
            switch a.first ?? "" {
            case "sample": ed.sample = EditorPreviewSample.allCases.first { "\($0)" == a.last } ?? .typescript
            case "hover": ed.hover(color)
            case "color": if let color { ed.open(color, anchor: a.count > 2 ? EditorPreviewSample.anchor(of: color, in: ed.sample) : "row-\(color.rawValue)") }
            case "close": ed.close()
            case "set": if let color, a.count > 2 { ed.commit(color, a[2]) }
            case "confirm": ed.confirmReplace()
            case "reset": ed.reset(color)
            case "palette": if let p = a.last.flatMap(EditorPalette.init(rawValue:)) { ed.choose(p) }
            case "expand":
                let section: EditorColorSection? = switch a.last { case "syntax": .syntax; case "editor": .editor; case "diff": .diff; default: nil }
                if let section { ed.expanded.insert(section) }
            default: break
            }
        case "lsp":  // lsp <pyright|gopls|rust-analyzer> running [0…1] | failed <text> | clear | install: a Settings row's job (#102)
            let a = arg.split(separator: " ", maxSplits: 2).map(String.init)
            guard let package = a.first.flatMap(LspPackage.init(rawValue:)) else { return }
            let lsp = settings.model.lsp
            switch a.count > 1 ? a[1] : "" {
            case "running": lsp.jobs[package] = .running(a.count > 2 ? Double(a[2]) : nil)
            case "failed": lsp.jobs[package] = .failed(a.count > 2 ? a[2] : "")
            case "install": lsp.install(package)
            default: lsp.jobs[package] = nil
            }
        case "theme":  // theme dark-plus|graphite|navy: as Settings → Оформление → Тема (live)
            if let theme = AppTheme(rawValue: arg) {
                do { try app.setTheme(theme) } catch { uiLog.error("theme: \(error.localizedDescription, privacy: .public)") }
            }
        case "termbg":  // termbg hangar|ghostty: as Settings → Оформление → Фон терминала (live)
            if let bg = HangarConfig.TerminalBackground(rawValue: arg) { try? app.setTerminalBackground(bg) }
        case "keepAwake":  // keepAwake on|off|working <n>: the ☕ row's states (working holds a real assertion until quit)
            let f = arg.split(separator: " ").map(String.init)
            switch f.first ?? "" {
            case "on", "off": try? app.setConfig("keep_awake", flag: f[0] == "on") { $0.keepAwake = f[0] == "on" }
            case "working": app.keepAwake.update(working: f.count > 1 ? Int(f[1]) ?? 0 : 0, enabled: app.config.keepAwake)
            default: break
            }
        case "inbox":  // inbox open|close|snap <png>: the «Входящие» popover
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch f.first ?? "" {
            case "open": if !app.inboxShown { app.toggleInbox() }
            case "close": app.setInboxShown(false)
            case "snap" where f.count > 1:
                guard let view = popoverWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: f[1]))
            default: break
            }
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
                let list = BranchListView(selection: Binding(get: { model.base }, set: { model.base = $0 }),
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
        case "ntName": newTaskModelForDebug?.name = arg  // as if typed into the name field
        case "ntCreate":  // ⌘↩ into the sheet: its own «Создать» button (keyboard shortcut) runs, as a user's would
            if let sheet = window?.attachedSheet,
               let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                uiLog.info("ntCreate handled=\(sheet.performKeyEquivalent(with: e))")
            }
        case "ntState":  // the sheet's progress and errors
            if let m = newTaskModelForDebug {
                uiLog.info("nt creating=\(m.creating) progress=\(m.progress ?? "-", privacy: .public) error=\(m.createError ?? "-", privacy: .public)")
            }
        case "ntWorktree": newTaskModelForDebug?.worktree = arg == "on"  // the Worktree toggle
        case "ntSetup": newTaskModelForDebug?.runSetup = arg == "on"  // the setup-command consent toggle
        case "windows": uiLog.info("windows: \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) key=\($0.isKeyWindow)" }, privacy: .public) badge=\(NSApp.dockTile.badgeLabel ?? "-", privacy: .public)")
        case "inspector":
            // inspector [files|changes|toggleMode|expand <dir>|click <row>]: drives the inspector; logs its rows.
            // With no argument it shows the selected task even when the window is occluded (the watcher stays off).
            let m = app.inspector
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch f.first ?? "" {
            case "files": m.segment = .files
            case "changes": m.segment = .changes
            case "git": m.segment = .git
            case "toggleMode": m.toggleMode()
            case "expand": if f.count > 1 { m.expand(f[1]) }
            case "diff": if f.count > 1 { m.loadDiff(path: f[1]) }
            // change <n>: a click on the n-th Changes row (0-based) → the diff tab.
            case "change": if f.count > 1, let n = Int(f[1]), let files = m.changes?.files, files.indices.contains(n) { app.openDiff(path: files[n].path) }
            // menu <path>: a Files/Changes row's right-click menu, 200/120 pt into the window from the right.
            case "menu": if f.count > 1, let frame = window?.frame {
                PopoverMenu.show(fileMenu(app: app, relative: f[1], opens: true), at: NSPoint(x: frame.maxX - 300, y: frame.maxY - 120))
            }
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
                    // The Git tab too, so an occluded verification window (HANGAR_DEBUG_BEHIND) still loads the log.
                    app.gitPanel.show(taskId: task.id, root: root, git: { Git(repo: $0, runner: runner) }, remote: !runner.isLocal)
                    app.gitPanel.setOnScreen(true)
                }
            default: break
            }
            uiLog.info("inspector visible=\(self.app.state.inspectorVisible) width=\(self.inspectorItem.viewController.view.frame.width) state=\(self.app.state.inspectorWidth) occlusion=\(self.window?.occlusionState.contains(.visible) ?? false) git=\(m.isGit) root=\(m.root ?? "-", privacy: .public) rows=\(visibleRows(m.tree, expanded: m.expanded).map(\.id), privacy: .public) changes=\(m.changes?.files.map(\.path) ?? [], privacy: .public) mode=\(String(describing: m.changes?.mode), privacy: .public) base=\(m.baseName ?? "-", privacy: .public) error=\(m.error ?? "-", privacy: .public) diffPath=\(m.diffPath ?? "-", privacy: .public) diff=\(Self.describe(m.diff), privacy: .public) diffTab=\(self.app.selectedTask.flatMap { self.app.diffTabs[$0.id] }.map { "\($0.path) active=\($0.active) row=\(self.app.activeDiffSelection.map(String.init) ?? "-")" } ?? "-", privacy: .public) rows=\(self.app.activeDiffContent.rows.count) open=\(self.app.activeDiff.flatMap { _ in openTarget(rows: self.app.activeDiffContent.rows, selected: self.app.activeDiffSelection) }.map(String.init) ?? "-", privacy: .public) responder=\(self.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-", privacy: .public)")
        case "palette":  // palette open|commands|close|type <query>|up|down|enter|snap <png>; state goes to the log
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let rest = f.count > 1 ? f[1] : ""
            switch f.first ?? "" {
            case "open": if palette == nil { togglePalette(commands: false) }
            case "commands": if palette == nil { togglePalette(commands: true) }
            case "close": closePalette()
            case "type": palette?.model.setQuery(rest)
            case "up": palette?.model.move(-1)
            case "down": palette?.model.move(1)
            case "enter": if let item = palette?.model.highlighted { let pick = debugPalettePickFor; closePalette(); choosePalette(item, pickFor: pick) }
            case "snap":
                guard let view = palette?.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: rest))
            default: break
            }
            let rows = palette?.model.sections.map { "\($0.kind):\($0.items.map(\.title))" } ?? []
            uiLog.info("palette open=\(self.palette != nil, privacy: .public) frame=\(NSStringFromRect(self.palette?.panel.frame ?? .zero), privacy: .public) visible=\(self.palette?.panel.isVisible ?? false, privacy: .public) commands=\(self.palette?.model.isCommands ?? false, privacy: .public) loading=\(self.palette?.model.showsLoading ?? false, privacy: .public) highlight=\(self.palette?.model.highlight ?? "-", privacy: .public) rows=\(rows, privacy: .public)")
        case "resize":  // resize <w> <h>: the window's content size (screenshots at a known size)
            let v = arg.split(separator: " ").compactMap { Double($0) }
            if v.count == 2 { window?.setContentSize(NSSize(width: v[0], height: v[1])); window?.center(); park(window) }
        case "remote":
            // remote sheet | fill <host> <path> | connect | add | server <host> | refresh | spec <file> | install | review claude|codex [remove] | confirm | snap <file> | close | dump
            let f = arg.split(separator: " ").map(String.init)
            let m = remoteProjectModel
            let server = serverModel ?? m?.server
            switch f.first ?? "" {
            case "sheet": presentRemoteProject()
            case "fill": if f.count == 3 { m?.host = f[1]; m?.path = f[2] }
            case "connect": if let m { Task { await m.connect() } }
            case "add": if let m, let path = m.foundPath { remoteProjectAdd?(m.host, path) }
            case "server": if f.count == 2 { presentServer(f[1]) }
            case "spec": if f.count == 2 { try? server?.terminalSpec()?.command.write(toFile: f[1], atomically: true, encoding: .utf8) }
            case "refresh": if let server { Task { await server.refresh() } }
            case "optional":  // optional <tool>: ticks/unticks its «Необязательно» checkbox
                if f.count == 2, let server, let tool = RemoteTool(rawValue: f[1]) {
                    if server.optional.contains(tool) { server.optional.remove(tool) } else { server.optional.insert(tool) }
                }
            case "review": if let server { Task { await server.review(f.count > 1 && f[1] == "codex" ? .codex : .claude, install: !(f.count > 2 && f[2] == "remove")) } }
            case "confirm": if let server { Task { await server.confirmPlan() } }  // = «Применить» in the diff sheet
            case "snap":  // the diff sheet on top of the remote sheet
                guard f.count == 2, let view = window?.attachedSheet?.attachedSheet?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: f[1]))
            case "install": server?.startInstall()  // = «Установить» (the user's confirmation)
            case "close": if let sheet = window?.attachedSheet { window?.endSheet(sheet) }  // debug only: models stay until the next sheet
            default: break
            }
            let hosts = app.remote.hosts.map { "\($0.key)=\($0.value.state) attention=\($0.value.needsAttention)" }
            uiLog.info("remote hosts=\(hosts, privacy: .public) phase=\(String(describing: server?.phase), privacy: .public) report=\(server?.report.map { "remote=\($0.remoteVersion ?? 0) tools=\($0.tools.keys.map(\.rawValue).sorted())" } ?? "-", privacy: .public)")
            uiLog.info("remote phase=\(String(describing: m?.phase), privacy: .public) server=\(String(describing: server?.phase), privacy: .public) steps=\(server?.plan.steps.map(\.command) ?? [], privacy: .public) manual=\(server?.plan.manual.map(\.rawValue) ?? [], privacy: .public) terminal=\(server?.installSpec?.command ?? "-", privacy: .public) claude=\(String(describing: server?.claude), privacy: .public) hosts=\(hosts, privacy: .public) sheetWindow=\(self.window?.attachedSheet?.windowNumber ?? 0) main=\(self.window?.windowNumber ?? 0) sheetSize=\(String(describing: self.window?.attachedSheet?.frame.size), privacy: .public)")
        case "window":
            // window minimize|restore|hide|unhide|out|front: occlusion changes without activating the app.
            switch arg {
            case "minimize": window?.miniaturize(nil)
            case "restore": window?.deminiaturize(nil)
            case "hide": NSApp.hide(nil)
            case "unhide": NSApp.unhideWithoutActivation()
            case "out": window?.orderOut(nil)
            case "front": window?.orderFrontRegardless()
            case "back": window?.orderBack(nil)
            default: break
            }
            uiLog.info("window \(arg, privacy: .public) occlusion=\(self.window?.occlusionState.contains(.visible) ?? false) mini=\(self.window?.isMiniaturized ?? false) active=\(NSApp.isActive)")
        case "check": try? column.terminalArea.debugCheck().write(toFile: arg, atomically: true, encoding: .utf8)  // check <file>
        case "surfaces": try? column.terminalArea.debugSurfaces().write(toFile: arg, atomically: true, encoding: .utf8)  // surfaces <file>
        case "merge", "moveLeaf", "detach": debugMove(parts[0], arg.split(separator: " ").map(String.init))
        // Runs applicationWillTerminate like ⌘Q. From a run-loop block, not this main-queue callback: the quit sheet's
        // nested loop could not drain the main queue (the SIGTERM source) while a main-queue block is on the stack.
        case "quit": RunLoop.main.perform { NSApp.terminate(nil) }
        // notices <file>: what would be on screen, one per line (no bundle in DEBUG, so no real banners).
        case "notices":
            let lines = debugNotices.enumerated().map { i, n in
                "\(i) id=\(n.id) category=\(n.category.rawValue) thread=\(n.thread ?? "-") sound=\(n.sound ?? "-") key=\(n.requestKey?.uuidString ?? "-") title=\(n.title) subtitle=\(n.subtitle) body=\(n.body)"
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        // noticeAction <n> open|allow [<request key>]|limits|reply <text>: as the n-th notice's button (a key: an older banner's).
        case "noticeAction":
            let f = arg.split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count >= 2, let n = Int(f[0]), debugNotices.indices.contains(n) else { return }
            let action: NoticeAction? = switch f[1] {
            case "open": .open
            case "allow": .allow
            case "limits": .limits
            case "reply": .reply(f.count > 2 ? f[2] : "")
            default: nil
            }
            let notice = debugNotices[n]
            let key = f.count > 2 && f[1] == "allow" ? UUID(uuidString: f[2]) : nil
            if let action { noticeAction(leaf: notice.leaf, requestKey: key ?? notice.requestKey, action) }
        case "dump":
            let tasks = app.state.tasks.map { t in
                "\(t.name) archived=\(t.archived) pinned=\(t.pinned) order=\(t.order) tabs=\(t.tabs.map { "\($0.id == t.activeTabId ? "*" : "")\(app.tabLabel($0)) leaves=\($0.root.leaves.map { $0.id.uuidString.prefix(4) }) focus=\($0.focusedLeafId.uuidString.prefix(4))" }) active=\(t.activeTabId == nil ? "-" : "set") drawer=\(t.drawer.visible)/\(Int(t.drawer.height))/\(t.drawer.leaf?.id.uuidString.prefix(4) ?? "-")"
            } + debugAgents() + ["projects=\(app.state.projects.map { "\($0.name)@\($0.path)" }) renaming=\(app.renaming.map { "\($0)" } ?? "-") responder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") sheet=\(window?.attachedSheet != nil) active=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false)"]
            // dump <file>: the full text to a file too (the unified log truncates long lines).
            if !arg.isEmpty { try? (tasks.joined(separator: "\n") + "\n" + column.terminalArea.debugDump()).write(toFile: arg, atomically: true, encoding: .utf8) }
            uiLog.info("dump selected=\(self.app.selectedTask?.name ?? "-", privacy: .public) sidebar=\(self.app.state.sidebarWidth)/\(self.app.state.sidebarCollapsed) actual=\(self.sidebarItem.viewController.view.frame.width) panes=\(self.split.splitView.subviews.map { Int($0.frame.width) }, privacy: .public) win=\(Int(self.window?.frame.width ?? 0))x\(Int(self.window?.contentView?.frame.height ?? 0))\n\(tasks.joined(separator: "\n"), privacy: .public)\n\(self.column.terminalArea.debugDump(), privacy: .public)")
        default: _ = debugEditor(parts.first ?? "", arg)
        }
    }
}
#endif
