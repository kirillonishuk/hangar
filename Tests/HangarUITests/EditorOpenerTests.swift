import Foundation
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct EditorOpenerTests {
    @Test func helixQuoting() {
        #expect(helixQuoted("/r/a b.txt") == "'/r/a b.txt'")
        #expect(helixQuoted("/r/it's.txt") == "`/r/it's.txt`")
        #expect(helixQuoted("/r/it's `x`.txt") == "\"/r/it's `x`.txt\"")
        #expect(helixQuoted("/r/it's `x` \"y\".txt") == nil)
        #expect(helixQuoted("/r/it's `x` %y.txt") == nil)
        // Helix does not expand `%{}` inside single quotes.
        #expect(helixQuoted("/r/%{sh}.txt") == "'/r/%{sh}.txt'")
        // A newline would end the pasted command line early.
        #expect(helixQuoted("/r/a\nb.txt") == nil)
    }

    @Test func helixCommandsWithLine() {
        #expect(helixCommands(path: "/r/a.txt", line: 12) == ["open '/r/a.txt'", "goto 12"])
        #expect(helixCommands(path: "/r/a.txt", line: nil) == ["open '/r/a.txt'"])
        #expect(helixCommands(path: "/r/a.txt", line: 0) == ["open '/r/a.txt'"])
        #expect(helixCommands(path: "/r/'`\".txt", line: 3) == nil)
    }

    private func leaf(_ kind: LeafKind) -> Leaf { Leaf(kind: kind, cwd: "/r") }

    private func task(_ tabs: [Tab], active: Int?) -> HangarTask {
        HangarTask(projectId: UUID(), name: "t", order: 0, tabs: tabs, activeTabId: active.map { tabs[$0].id })
    }

    private func split(_ a: Leaf, _ b: Leaf, focus: Leaf) -> Tab {
        Tab(title: "s", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)), focusedLeafId: focus.id)
    }

    private func single(_ l: Leaf) -> Tab { Tab(title: l.kind.rawValue, root: .leaf(l), focusedLeafId: l.id) }

    @Test func routePrefersFocusedEditor() {
        let shell = leaf(.shell), ed = leaf(.editor), other = leaf(.editor), ed2 = leaf(.editor)
        let live: (UUID) -> Bool = { _ in true }
        // [shell │ editor] focused on the editor + a separate editor tab.
        let focused = split(shell, ed, focus: ed), separate = single(other)
        #expect(editorRoute(task: task([separate, focused], active: 1), isHelix: true, quotable: true, isLive: live)
                == .sendKeys(tab: focused.id, leaf: ed.id))
        // Focus on the shell: the first editor leaf of the active tab.
        let two = Tab(title: "s", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(shell),
                                               second: .split(axis: .vertical, ratio: 0.5, first: .leaf(ed), second: .leaf(ed2))),
                      focusedLeafId: shell.id)
        #expect(editorRoute(task: task([separate, two], active: 1), isHelix: true, quotable: true, isLive: live)
                == .sendKeys(tab: two.id, leaf: ed.id))
        // Focus on the second editor: that one.
        var twoFocused = two; twoFocused.focusedLeafId = ed2.id
        #expect(editorRoute(task: task([separate, twoFocused], active: 1), isHelix: true, quotable: true, isLive: live)
                == .sendKeys(tab: two.id, leaf: ed2.id))
        // The active tab has no editor: the first editor leaf in tab order.
        let shellTab = single(leaf(.claude))
        #expect(editorRoute(task: task([shellTab, separate, focused], active: 0), isHelix: true, quotable: true, isLive: live)
                == .sendKeys(tab: separate.id, leaf: other.id))
        // No active tab at all.
        #expect(editorRoute(task: task([shellTab, separate], active: nil), isHelix: true, quotable: true, isLive: live)
                == .sendKeys(tab: separate.id, leaf: other.id))
    }

    @Test func routeFallbacks() {
        let ed = leaf(.editor)
        let tab = single(ed)
        let withEditor = task([tab], active: 0)
        #expect(editorRoute(task: task([single(leaf(.shell))], active: 0), isHelix: true, quotable: true) { _ in true } == .newTab)
        #expect(editorRoute(task: task([], active: nil), isHelix: true, quotable: true) { _ in true } == .newTab)
        #expect(editorRoute(task: withEditor, isHelix: false, quotable: true) { _ in true } == .newTab)
        #expect(editorRoute(task: withEditor, isHelix: true, quotable: false) { _ in true } == .newTab)
        #expect(editorRoute(task: withEditor, isHelix: true, quotable: true) { _ in false } == .launch(tab: tab.id, leaf: ed.id))
        var asked: [UUID] = []
        _ = editorRoute(task: withEditor, isHelix: true, quotable: true) { asked.append($0); return true }
        #expect(asked == [ed.id])
    }
}
