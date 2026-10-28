import AppKit
import Foundation
import Testing
@testable import HangarUI
@testable import Workspace

/// Drag a tab onto a pane edge (splits spec §2): zones and target resolution, no window.
@MainActor @Suite struct PaneDragTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)

    /// Session with tabs A (active, claude leaf a) and B (shell).
    private func two() -> (s: WorkspaceState, t: UUID, a: UUID, b: UUID, al: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let b = s.addTab(taskId: t, kind: .shell)
        s.tasks[0].activeTabId = a
        return (s, t, a, b, s.tasks[0].tabs[0].root.leaves[0].id)
    }

    @Test func dropEdgeZones() {
        #expect(dropEdge(in: rect, at: CGPoint(x: 10, y: 100)) == .left)
        #expect(dropEdge(in: rect, at: CGPoint(x: 390, y: 100)) == .right)
        #expect(dropEdge(in: rect, at: CGPoint(x: 200, y: 10)) == .top)
        #expect(dropEdge(in: rect, at: CGPoint(x: 200, y: 190)) == .bottom)
        #expect(dropEdge(in: rect, at: CGPoint(x: 200, y: 100)) == nil)
        #expect(dropEdge(in: rect, at: CGPoint(x: 500, y: 100)) == nil)
        // In a corner both zones apply: the nearer side by its share of the pane wins.
        #expect(dropEdge(in: rect, at: CGPoint(x: 20, y: 5)) == .top)
    }

    @Test func tabDropOnOtherTabsPane() {
        let (s, t, a, b, al) = two()
        let target = resolveDrop(.tab(b), at: CGPoint(x: 390, y: 100), state: s, taskId: t, activeTab: a,
                                 paneFrames: [al: rect], tabBar: nil, tabFrames: [:])
        #expect(target == .edge(tab: a, leaf: al, .right))
        // Outside every pane, or in its middle: nothing.
        #expect(resolveDrop(.tab(b), at: CGPoint(x: 200, y: 100), state: s, taskId: t, activeTab: a,
                            paneFrames: [al: rect], tabBar: nil, tabFrames: [:]) == nil)
        #expect(resolveDrop(.tab(b), at: CGPoint(x: 900, y: 100), state: s, taskId: t, activeTab: a,
                            paneFrames: [al: rect], tabBar: nil, tabFrames: [:]) == nil)
    }

    @Test func dropOnOwnPanesIsNil() {
        let (s, t, a, _, al) = two()
        for p in [CGPoint(x: 10, y: 100), CGPoint(x: 390, y: 100), CGPoint(x: 200, y: 10), CGPoint(x: 200, y: 190)] {
            #expect(resolveDrop(.tab(a), at: p, state: s, taskId: t, activeTab: a, paneFrames: [al: rect], tabBar: nil, tabFrames: [:]) == nil)
        }
    }

    /// The diff tab or «Сессии» on screen: `paneFrames` is empty (ruling R3).
    @Test func noPaneTargetsWhileDiffShown() {
        let (s, t, a, b, _) = two()
        for x in stride(from: 0.0, through: 400, by: 50) {
            for y in stride(from: 0.0, through: 200, by: 50) {
                #expect(resolveDrop(.tab(b), at: CGPoint(x: x, y: y), state: s, taskId: t, activeTab: a,
                                    paneFrames: [:], tabBar: nil, tabFrames: [:]) == nil)
            }
        }
    }

    @Test func tabDropRespectsEditorCap() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo")
        let t = s.addTask(projectId: p, name: "t")
        let a = s.addTab(taskId: t, kind: .claude)
        let leaf = s.tasks[0].tabs[0].root.leaves[0].id
        let c1 = s.split(taskId: t, tabId: a, leafId: leaf, axis: .horizontal, kind: nil)
        let c2 = s.split(taskId: t, tabId: a, leafId: leaf, axis: .horizontal, kind: nil)
        _ = s.chooseKind(leafId: c1, kind: .editor, file: "/repo/x.ts")
        _ = s.chooseKind(leafId: c2, kind: .editor, file: "/repo/y.ts")
        let f0 = s.openFileTab(taskId: t, path: "/repo/z.ts", line: nil, column: nil, preview: false)
        let f = try #require(f0)
        s.tasks[0].activeTabId = a
        #expect(resolveDrop(.tab(f.tab), at: CGPoint(x: 390, y: 100), state: s, taskId: t, activeTab: a,
                            paneFrames: [leaf: rect], tabBar: nil, tabFrames: [:]) == nil)
    }

    /// Tab A = split(a, b) (a left, b right), active; tab B (shell) next to it.
    private func splitTwo() -> (s: WorkspaceState, t: UUID, A: UUID, B: UUID, a: UUID, b: UUID) {
        var (s, t, A, B, a) = two()
        let b = s.split(taskId: t, tabId: A, leafId: a, axis: .horizontal, kind: .shell)
        s.tasks[0].activeTabId = A
        return (s, t, A, B, a, b)
    }

    private let left = CGRect(x: 0, y: 40, width: 200, height: 200), right = CGRect(x: 202, y: 40, width: 200, height: 200)
    private let bar = CGRect(x: 0, y: 0, width: 800, height: 40)

    @Test func insertionIndexBetweenTabs() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 30), CGRect(x: 102, y: 0, width: 100, height: 30),
                      CGRect(x: 204, y: 0, width: 100, height: 30)]
        #expect(insertionIndex(x: 10, frames: frames) == 0)
        #expect(insertionIndex(x: 150, frames: frames) == 1)
        #expect(insertionIndex(x: 400, frames: frames) == 3)
        #expect(insertionIndex(x: 10, frames: []) == 0)
    }

    @Test func leafDropOnSiblingEdge() {
        let (s, t, A, _, a, b) = splitTwo()
        let frames = [a: left, b: right]
        #expect(resolveDrop(.leaf(b), at: CGPoint(x: 10, y: 140), state: s, taskId: t, activeTab: A,
                            paneFrames: frames, tabBar: bar, tabFrames: [:]) == .edge(tab: A, leaf: a, .left))
        #expect(resolveDrop(.leaf(a), at: CGPoint(x: 300, y: 235), state: s, taskId: t, activeTab: A,
                            paneFrames: frames, tabBar: bar, tabFrames: [:]) == .edge(tab: A, leaf: b, .bottom))
        // The sibling's middle: nothing.
        #expect(resolveDrop(.leaf(b), at: CGPoint(x: 100, y: 140), state: s, taskId: t, activeTab: A,
                            paneFrames: frames, tabBar: bar, tabFrames: [:]) == nil)
    }

    @Test func leafDropOnItselfIsNil() {
        let (s, t, A, _, a, b) = splitTwo()
        for p in [CGPoint(x: 300, y: 140), CGPoint(x: 210, y: 140), CGPoint(x: 395, y: 140), CGPoint(x: 300, y: 45), CGPoint(x: 300, y: 235)] {
            #expect(resolveDrop(.leaf(b), at: p, state: s, taskId: t, activeTab: A, paneFrames: [a: left, b: right],
                                tabBar: bar, tabFrames: [:]) == nil)
        }
    }

    @Test func leafDropOnTabBar() {
        let (s, t, A, B, a, b) = splitTwo()
        let tabFrames = [A: CGRect(x: 0, y: 5, width: 100, height: 35), B: CGRect(x: 102, y: 5, width: 100, height: 35)]
        func drop(_ x: CGFloat) -> PaneDropTarget? {
            resolveDrop(.leaf(b), at: CGPoint(x: x, y: 20), state: s, taskId: t, activeTab: A, paneFrames: [a: left, b: right],
                        tabBar: bar, tabFrames: tabFrames)
        }
        #expect(drop(10) == .tabBar(index: 0))
        #expect(drop(150) == .tabBar(index: 1))
        #expect(drop(600) == .tabBar(index: 2))
        // A pane of an unsplit tab has no header to drag: it can't be detached.
        let (s2, t2, A2, _, a2) = two()
        #expect(resolveDrop(.leaf(a2), at: CGPoint(x: 10, y: 20), state: s2, taskId: t2, activeTab: A2, paneFrames: [:],
                            tabBar: bar, tabFrames: tabFrames) == nil)
    }

    /// The diff tab / «Сессии» cover the panes (empty `paneFrames`, ruling R3): no edge for a pane either.
    @Test func leafNoPaneTargetsWhileDiffShown() {
        let (s, t, A, _, _, b) = splitTwo()
        #expect(resolveDrop(.leaf(b), at: CGPoint(x: 10, y: 140), state: s, taskId: t, activeTab: A, paneFrames: [:],
                            tabBar: bar, tabFrames: [:]) == nil)
    }

    /// The chip under the pointer names what is dragged.
    @Test func chipShowsDraggedTab() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pane-drag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (s, _, a, b, _) = two()
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        let tabB = try #require(app.state.tasks[0].tabs.first { $0.id == b })
        let chip = try #require(paneDragChip(.tab(b), app: app))
        #expect(chip.icon == .shell && chip.title == app.tabLabel(tabB))
        #expect(paneDragChip(.tab(UUID()), app: app) == nil)
        _ = a
    }

    @Test func dropLabels() {
        let saved = L10n.language
        defer { L10n.language = saved }
        L10n.language = .ru
        #expect([SplitEdge.right, .left, .top, .bottom].map(paneDropLabel) == ["Справа", "Слева", "Сверху", "Снизу"])
        L10n.language = .en
        #expect([SplitEdge.right, .left, .top, .bottom].map(paneDropLabel) == ["Right", "Left", "Top", "Bottom"])
    }

    // MARK: Controller lifecycle

    /// A window with a tab bar strip on top and the terminal area below; two chooser tabs (no processes).
    private func makeController() -> (PaneDragController, AppState, NSWindow, b: UUID, dir: URL) {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .choose)
        let b = s.addTab(taskId: t, kind: .choose)
        s.selectedTaskId = t
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pane-drag-\(UUID().uuidString)")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bar = NSView(frame: NSRect(x: 0, y: 560, width: 800, height: 40))
        let area = TerminalArea(app: app)
        area.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        window.contentView!.addSubview(bar)
        window.contentView!.addSubview(area)
        return (PaneDragController(app: app, area: area, tabBar: bar), app, window, b, dir)
    }

    /// SwiftUI drops `onEnded` when the app deactivates / the window resigns key mid-drag: the controller cleans up itself.
    @Test func resignMidDragCleansUp() throws {
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            let (c, app, window, b, dir) = makeController()
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(c.update(.tab(b), at: CGPoint(x: 400, y: 300)))
            #expect(c.active && c.cursorLocked)
            NotificationCenter.default.post(name: name, object: name == NSApplication.didResignActiveNotification ? NSApp : window)
            #expect(!c.active && !c.cursorLocked, "\(name.rawValue)")
            #expect(app.paneDropTarget == nil)
            // Another window's resign does nothing to a later drag.
            #expect(c.update(.tab(b), at: CGPoint(x: 400, y: 300)))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
            #expect(c.active && c.cursorLocked)
            #expect(c.end(.tab(b)))
            #expect(!c.active && !c.cursorLocked)
        }
    }

    /// Esc unlocks at once; the gesture's later moves do nothing and its end is swallowed.
    @Test func escCancelsTheRestOfTheDrag() throws {
        let (c, _, _, b, dir) = makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(c.update(.tab(b), at: CGPoint(x: 400, y: 300)))
        #expect(c.cancel())
        #expect(!c.cursorLocked)
        #expect(!c.cancel())  // a second Esc goes on as usual
        #expect(c.update(.tab(b), at: CGPoint(x: 400, y: 20)))  // even back over the tab bar: no reorder
        #expect(!c.cursorLocked)
        #expect(c.end(.tab(b)))
        #expect(c.update(.tab(b), at: CGPoint(x: 400, y: 300)) && c.cursorLocked)  // the next drag works
        c.abort()
        #expect(!c.active && !c.cursorLocked)
    }

    /// A pane header dragged into the tab bar: the slot index from the tab frames; the drop detaches it there.
    @Test func leafDragIntoTabBarDetaches() throws {
        let (c, app, _, b, dir) = makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = app.state.tasks[0].id, first = app.state.tasks[0].tabs[0]
        app.perform { $0.split(taskId: t, tabId: first.id, leafId: first.root.leaves[0].id, axis: .horizontal, kind: .shell) }
        app.perform { $0.tasks[0].activeTabId = first.id }
        let moved = try #require(app.state.tasks[0].tabs[0].root.leaves.last?.id)
        app.tabFrames = [first.id: CGRect(x: 0, y: 5, width: 100, height: 35), b: CGRect(x: 102, y: 5, width: 100, height: 35)]
        #expect(c.update(.leaf(moved), at: CGPoint(x: 300, y: 20)))  // the bar is 0…40 from the top
        #expect(app.paneDropTarget == .tabBar(index: 2) && c.cursorLocked)
        #expect(c.end(.leaf(moved)))
        #expect(!c.active && !c.cursorLocked && app.paneDropTarget == nil)
        let tabs = app.state.tasks[0].tabs
        let detached = try #require(tabs[2].root.leaf(id: moved))
        #expect(tabs.count == 3 && tabs[2].root == .leaf(detached))
        #expect(app.state.tasks[0].tabs[0].root.leaves.count == 1)
    }

    /// Esc during a header drag: nothing moves.
    @Test func leafDragEscDropsNothing() throws {
        let (c, app, _, _, dir) = makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = app.state.tasks[0].id, first = app.state.tasks[0].tabs[0]
        app.perform { $0.split(taskId: t, tabId: first.id, leafId: first.root.leaves[0].id, axis: .horizontal, kind: .shell) }
        let moved = try #require(app.state.tasks[0].tabs[0].root.leaves.last?.id)
        let before = app.state.tasks[0].tabs
        #expect(c.update(.leaf(moved), at: CGPoint(x: 300, y: 20)))
        #expect(c.cancel())
        #expect(c.end(.leaf(moved)))
        #expect(app.state.tasks[0].tabs == before)
    }

    /// The chip stays inside the window near its right and bottom edges.
    @Test func chipStaysInside() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600), size = NSSize(width: 120, height: 28)
        let off = Theme.paneDragGhostOffset
        #expect(PaneDragGhost.placement(size, pointer: NSPoint(x: 100, y: 300), in: bounds) == NSRect(x: 100 + off, y: 300 - off - 28, width: 120, height: 28))
        let corner = PaneDragGhost.placement(size, pointer: NSPoint(x: 795, y: 5), in: bounds)
        #expect(bounds.contains(corner))
        #expect(corner.maxX <= 795 && corner.minY >= 5)  // flipped to the pointer's other side, not under it
    }
}
