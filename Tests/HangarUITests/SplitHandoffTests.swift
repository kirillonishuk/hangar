import AppKit
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// Live panes change tabs (merge, move, detach) without their view ever leaving the window (no relaunch, no blank terminal).
@MainActor @Suite struct SplitHandoffTests {
    /// One task with two chooser tabs (no processes), shown in an offscreen window.
    private func makeArea() -> (app: AppState, area: TerminalArea, window: NSWindow, a: UUID, b: UUID) {
        var s = WorkspaceState()
        let p = s.addProject(name: "p", path: "/tmp")
        let t = s.addTask(projectId: p, name: "t")
        s.addTab(taskId: t, kind: .choose)
        s.addTab(taskId: t, kind: .choose)
        s.selectedTaskId = t
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-handoff-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let area = TerminalArea(app: app)
        area.frame = window.contentView!.bounds
        window.contentView!.addSubview(area)
        // The app's window lays out with Auto Layout (SwiftUI hosting views): a constrained view turns the engine on here too.
        let constrained = NSView()
        constrained.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(constrained)
        NSLayoutConstraint.activate([constrained.widthAnchor.constraint(equalToConstant: 1), constrained.heightAnchor.constraint(equalToConstant: 1)])
        let tabs = app.state.tasks[0].tabs
        window.orderBack(nil)
        for tab in tabs {
            app.activate(tabId: tab.id)
            area.sync()
        }
        return (app, area, window, tabs[0].id, tabs[1].id)
    }

    /// A real display pass: NSSplitView applies some frames only when the window draws.
    private func settle(_ window: NSWindow) {
        window.contentView!.layoutSubtreeIfNeeded()
        window.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func leafId(_ app: AppState, tab: UUID) -> UUID {
        app.state.tasks[0].tabs.first { $0.id == tab }!.root.leaves[0].id
    }

    @Test func mergedLeafViewNeverLeavesWindow() throws {
        let (app, area, window, a, b) = makeArea()
        let leafA = leafId(app, tab: a), leafB = leafId(app, tab: b)
        let view = try #require(area.leafViews[leafB])
        let before = ObjectIdentifier(view)
        app.mergeTab(b, into: a, at: leafA, edge: .right)
        area.sync()
        let after = try #require(area.leafViews[leafB])
        #expect(ObjectIdentifier(after) == before)
        #expect(after.isDescendant(of: try #require(area.tabViews[a])))
        #expect(after.window === window)
        #expect(!after.isHidden)
        #expect(after.windowLosses == 0)
        #expect(area.leafViews[leafA]?.windowLosses == 0)
        #expect(!area.debugCheck().contains("PROBLEM orphan"))
    }

    @Test func detachedLeafKeepsView() throws {
        let (app, area, window, a, b) = makeArea()
        let leafA = leafId(app, tab: a), leafB = leafId(app, tab: b)
        app.mergeTab(b, into: a, at: leafA, edge: .bottom)
        area.sync()
        let view = try #require(area.leafViews[leafB])
        app.detachLeaf(leafB, toIndex: nil)
        area.sync()
        let tab = try #require(app.location(ofLeaf: leafB)?.tab)
        #expect(tab != a)
        let after = try #require(area.leafViews[leafB])
        #expect(after === view)
        #expect(after.isDescendant(of: try #require(area.tabViews[tab])))
        #expect(after.window === window)
        #expect(after.windowLosses == 0)
        settle(window)
        #expect(after.translatesAutoresizingMaskIntoConstraints)
        #expect(after.frame == area.tabViews[tab]?.bounds)
        #expect(area.leafViews[leafA]?.frame == area.tabViews[a]?.bounds)
        #expect(!area.debugCheck().contains("PROBLEM orphan"))
    }

    @Test func movedLeafKeepsView() throws {
        let (app, area, window, a, b) = makeArea()
        let leafA = leafId(app, tab: a), leafB = leafId(app, tab: b)
        let view = try #require(area.leafViews[leafA])
        app.activate(tabId: a)
        area.sync()
        app.moveLeaf(leafA, to: b, at: leafB, edge: .left)
        area.sync()
        #expect(app.state.tasks[0].tabs.map(\.id) == [b])
        #expect(area.leafViews[leafA] === view)
        #expect(view.isDescendant(of: try #require(area.tabViews[b])))
        #expect(view.window === window)
        #expect(view.windowLosses == 0)
        #expect(!area.debugCheck().contains("PROBLEM orphan"))
    }

    /// Closing one pane of a split (a shell's `exit`) keeps the other pane's view in place.
    @Test func closingOnePaneKeepsTheOther() throws {
        let (app, area, window, a, b) = makeArea()
        let leafA = leafId(app, tab: a), leafB = leafId(app, tab: b)
        app.mergeTab(b, into: a, at: leafA, edge: .right)
        area.sync()
        let view = try #require(area.leafViews[leafA])
        app.closeLeaf(leafB)
        area.sync()
        #expect(app.state.tasks[0].tabs.map { $0.root.leaves.map(\.id) } == [[leafA]])
        #expect(area.leafViews[leafA] === view)
        #expect(view.window === window)
        #expect(view.windowLosses == 0)
        settle(window)
        // NSSplitView turns this off for its panes; left off, the layout engine sized the survivor to 0×0 (looked closed).
        #expect(view.translatesAutoresizingMaskIntoConstraints)
        #expect(view.frame == area.tabViews[a]?.bounds)
    }

    @Test func paneTitlePrefersCustomTitle() throws {
        let (app, area, _, a, b) = makeArea()
        let leafA = leafId(app, tab: a), leafB = leafId(app, tab: b)
        app.mergeTab(b, into: a, at: leafA, edge: .right)
        area.sync()
        app.perform { $0.renameLeaf(leafId: leafB, title: "api") }
        let tab = try #require(app.state.tasks[0].tabs.first)
        let leaf = try #require(tab.root.leaf(id: leafB))
        #expect(app.paneTitle(leaf) == "api")
        // The tab keeps its first pane's name: renaming (or focusing) the second pane never resizes the tab.
        #expect(app.tabLabel(tab) == app.paneTitle(try #require(tab.root.leaves.first)))
        #expect(!app.tabLabel(tab).contains("│"))
    }
}
