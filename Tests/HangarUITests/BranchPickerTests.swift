import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct BranchPickerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `listBranches` order: newest commit first.
    private var branches: [Branch] {
        [Branch(name: "origin/feat", isRemote: true, lastCommit: now.addingTimeInterval(-60)),
         Branch(name: "origin/main", isRemote: true, lastCommit: now.addingTimeInterval(-3600)),
         Branch(name: "refactor-db", isRemote: false, lastCommit: now.addingTimeInterval(-7200))]
    }

    @Test func itemsRemoteFirstDefaultOnTop() {
        let items = branchPickerItems(branches, query: "", defaultBase: "origin/main", taskBranches: [])
        #expect(items.remote.map(\.branch.name) == ["origin/main", "origin/feat"])
        #expect(items.remote[0].meta == .isDefault)
        #expect(items.remote[1].meta == .age(now.addingTimeInterval(-60)))
        #expect(items.local.map(\.branch.name) == ["refactor-db"])
        #expect(items.local[0].meta == .age(now.addingTimeInterval(-7200)))
    }

    @Test func queryFiltersCaseInsensitive() {
        let items = branchPickerItems(branches, query: "FEAT", defaultBase: "origin/main", taskBranches: [])
        #expect(items.remote.map(\.branch.name) == ["origin/feat"])
        #expect(items.local.isEmpty)
    }

    @Test func taskBranchMeta() {
        let items = branchPickerItems(branches, query: "", defaultBase: "origin/main", taskBranches: ["refactor-db"])
        #expect(items.local[0].meta == .task)
    }

    @Test func ageLabels() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(ageLabel(since: now.addingTimeInterval(-30), now: now) == "только что")
        #expect(ageLabel(since: now.addingTimeInterval(-120), now: now) == "2 мин назад")
        #expect(ageLabel(since: now.addingTimeInterval(-3 * 3600), now: now) == "3 ч назад")
        #expect(ageLabel(since: now.addingTimeInterval(-3 * 86400), now: now) == "3 дн назад")
        #expect(L10n.updatedAgo(ageLabel(since: now.addingTimeInterval(-120), now: now)) == "обновлено 2 мин назад")
        L10n.language = .en
        #expect(ageLabel(since: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(ageLabel(since: now.addingTimeInterval(-120), now: now) == "2 min ago")
        #expect(ageLabel(since: now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(ageLabel(since: now.addingTimeInterval(-3 * 86400), now: now) == "3 d ago")
        #expect(L10n.updatedAgo("2 min ago") == "updated 2 min ago")
    }

    /// The palette's ↑/↓: clamped at the ends; an unknown highlight lands on the first row.
    @Test func paletteHighlightClamps() {
        let rows = ["a", "b", "c"]
        #expect(movedHighlight(nil, by: 1, in: rows) == "a")
        #expect(movedHighlight("b", by: 1, in: rows) == "c")
        #expect(movedHighlight("c", by: 1, in: rows) == "c")
        #expect(movedHighlight("a", by: -1, in: rows) == "a")
        #expect(movedHighlight("gone", by: -1, in: rows) == "a")
        #expect(movedHighlight(nil, by: 1, in: []) == nil)
    }

    /// The branch list is the one menu: group headers, the current branch checked and highlighted on open, ↑/↓ skip
    /// the headers, typing moves the highlight to the first match, a pick sets the selection.
    @Test func branchMenuGroupsChecksAndHighlights() throws {
        var chosen: String?? = .none
        let menu = branchMenu(selection: "origin/feat", branches: branches, defaultBase: "origin/main", taskBranches: [],
                              defaultOption: "auto") { chosen = $0 }
        let search = try #require(menu.search)
        #expect(search.highlightFirst)
        let all = menu.entries("")
        let titles = all.map { e -> String in
            switch e {
            case .header(let t): "# " + t
            case .item(let i): i.title + (i.checked ? " ✓" : "")
            case .separator: "—"
            }
        }
        #expect(titles == ["auto", "# " + L10n.branchesRemote, "origin/main", "origin/feat ✓", "# " + L10n.branchesLocal, "refactor-db"])
        let open = menuInitialHighlight(all, highlightFirst: true, preferChecked: true)
        #expect(open == 3)
        #expect(menuStep(all, from: open, by: 1) == 5)
        #expect(menuStep(all, from: 2, by: -1) == 0)
        // Typing: the default row goes, the first match is highlighted.
        let typed = menu.entries("refactor")
        #expect(typed.compactMap(\.item).map(\.title) == ["refactor-db"])
        #expect(menuInitialHighlight(typed, highlightFirst: true, preferChecked: false) == 1)
        all[0].item?.action()
        #expect(chosen == .some(nil))
        all[5].item?.action()
        #expect(chosen == .some("refactor-db"))
    }

    /// Plain menus highlight nothing until the keys or the pointer.
    @Test func plainMenuStartsWithoutHighlight() {
        let entries: [PopoverMenuEntry] = [.item(PopoverMenuItem(title: "a", checked: true) {})]
        #expect(menuInitialHighlight(entries, highlightFirst: false, preferChecked: true) == nil)
    }
}
