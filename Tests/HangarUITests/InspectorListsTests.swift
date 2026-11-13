import Foundation
import Testing
@testable import HangarUI
import Workspace

/// HD-163: search fragments, ref chips that fold into «+N», the agent a path goes to.
@Suite struct InspectorListsTests {
    @Test func hitFragmentKeepsTheMatchInView() {
        let line = String(repeating: "x", count: 50) + "needle" + " tail"
        let (text, ranges) = hitFragment(line, [50..<56], lead: 12)
        #expect(text == "…" + String(repeating: "x", count: 12) + "needle tail")
        #expect(ranges == [13..<19])
        let u = Array(text.utf16)
        #expect(String(decoding: u[ranges[0]], as: UTF16.self) == "needle")
        // Near the start: as it is.
        #expect(hitFragment("ab needle", [3..<9], lead: 12) == ("ab needle", [3..<9]))
        // A match partly before the cut is clipped; an earlier one dropped (only the first decides the cut).
        let two = hitFragment(String(repeating: "y", count: 30) + "ab", [30..<32, 0..<2], lead: 4)
        #expect(two.0 == "…yyyyab" && two.1 == [5..<7])
        // Never splits an emoji.
        let emoji = String(repeating: "z", count: 20) + "😀😀m"
        let e = hitFragment(emoji, [24..<25], lead: 3)
        #expect(e.0 == "…😀m" && e.1 == [3..<4])
    }

    @Test func refChipsFoldIntoMore() {
        let more = { (n: Int) -> CGFloat in n < 10 ? 20 : 26 }
        // Both fit.
        #expect(fitRefChips([40, 40], more: 0, room: 84, gap: 4, moreWidth: more) == 2)
        // One with «+1».
        #expect(fitRefChips([40, 40], more: 0, room: 70, gap: 4, moreWidth: more) == 1)
        // None: only «+2».
        #expect(fitRefChips([40, 40], more: 0, room: 30, gap: 4, moreWidth: more) == 0)
        // Already hidden ones count in the «+N».
        #expect(fitRefChips([40], more: 3, room: 64, gap: 4, moreWidth: more) == 1)
        #expect(fitRefChips([40], more: 3, room: 63, gap: 4, moreWidth: more) == 0)
        #expect(fitRefChips([], more: 0, room: 0, gap: 4, moreWidth: more) == 0)
    }

    @Test func chatAgentPrefersTheFocusedThenActiveTab() {
        let claude = Leaf(kind: .claude, cwd: "/p"), codex = Leaf(kind: .codex, cwd: "/p")
        let editor = Leaf(kind: .editor, cwd: "/p"), shell = Leaf(kind: .shell, cwd: "/p")
        let agentTab = Workspace.Tab(title: "c", root: .leaf(claude), focusedLeafId: claude.id)
        let fileTab = Workspace.Tab(title: "f", root: .split(axis: .horizontal, ratio: 0.5, first: .leaf(editor), second: .leaf(codex)),
                          focusedLeafId: editor.id)
        let shellTab = Workspace.Tab(title: "s", root: .leaf(shell), focusedLeafId: shell.id)
        var task = HangarTask(projectId: UUID(), name: "t", order: 0)
        task.tabs = [agentTab, fileTab, shellTab]
        let all: (UUID) -> Bool = { _ in true }
        task.activeTabId = fileTab.id
        #expect(chatAgentLeaf(task, running: all)?.id == codex.id)     // the active tab's agent, beside the editor
        task.activeTabId = shellTab.id
        #expect(chatAgentLeaf(task, running: all)?.id == claude.id)    // else the first agent in tab order
        #expect(chatAgentLeaf(task) { $0 == codex.id }?.id == codex.id) // only running ones
        #expect(chatAgentLeaf(task) { _ in false } == nil)
        #expect(chatLineRef("src/a.ts", from: 12, to: 30) == "src/a.ts:12-30")
        #expect(chatLineRef("src/a.ts", from: 7, to: 7) == "src/a.ts:7")
    }

    /// HD-163 trust boundary: ESC and other controls never reach the agent's paste; a line break refuses the path.
    @Test func chatPathTextSanitises() {
        #expect(chatPathText("src/a b.ts:3-9 ") == "src/a b.ts:3-9 ")
        #expect(chatPathText("x\u{1b}[201~y\u{7}\u{9b}z ") == "x[201~yz ")
        for bad in ["a\rb", "a\nb", "a\r\nb", "a\u{85}b", "a\u{2028}b"] { #expect(chatPathText(bad) == nil) }
    }
}
