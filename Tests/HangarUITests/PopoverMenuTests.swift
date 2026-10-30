import Foundation
import Observation
import Testing
@testable import HangarUI
import TestSupport

@MainActor @Suite struct PopoverMenuTests {
    private func item(_ title: String, icon: Icon? = nil, checked: Bool = false) -> PopoverMenuEntry {
        .item(PopoverMenuItem(title: title, icon: icon, checked: checked) {})
    }

    /// A check gets its own column only next to icons («все вкладки» keeps the tab's icon); alone it takes the icon slot.
    @Test func layoutColumnsAndHeight() {
        let tabs = PopoverMenuLayout([item("a", icon: .claude, checked: true), item("b", icon: .shell)])
        #expect(tabs.checkColumn && tabs.iconColumn)
        let branches = PopoverMenuLayout([.header("local"), item("main", checked: true), .separator, item("dev")])
        #expect(!branches.checkColumn && branches.iconColumn)
        #expect(branches.height == 3 * Theme.Height.rowList + 1 + 2 * Theme.menuPadding)
        let plain = PopoverMenuLayout([item("a"), item("b")])
        #expect(!plain.checkColumn && !plain.iconColumn)
    }

    @Observable final class Source { var names: [String] = [] }

    /// Entries are built once per text change, and again when the data they read arrives (authors loading).
    @Test func entriesRebuildOnQueryAndData() async {
        let source = Source()
        var builds = 0
        let content = PopoverMenuContent(search: .init(placeholder: "")) { q in
            builds += 1
            return source.names.filter { q.isEmpty || $0.contains(q) }.map { .item(PopoverMenuItem(title: $0) {}) }
        }
        let state = PopoverMenuState()
        state.refresh(content)
        #expect(state.entries.isEmpty)
        source.names = ["ada", "bob"]
        #expect(await waitUntil { state.entries.count == 2 })
        state.query = "b"
        state.refresh(content)
        #expect(state.entries.compactMap(\.item).map(\.title) == ["bob"])
        let before = builds
        state.highlighted = 0  // hover / keys: no rebuild
        #expect(builds == before)
    }
}
