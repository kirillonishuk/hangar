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

    /// ↑/↓ walk the rows of both sections; the highlight stays on the list.
    @Test func keyboardMovesThroughBothSections() {
        let items = branchPickerItems(branches, query: "", defaultBase: "origin/main", taskBranches: [])
        let rows = (items.remote + items.local).map(\.branch.name)
        #expect(movedHighlight(nil, by: 1, in: rows) == "origin/main")
        #expect(movedHighlight("origin/feat", by: 1, in: rows) == "refactor-db")
        #expect(movedHighlight("refactor-db", by: 1, in: rows) == "refactor-db")
        #expect(movedHighlight("origin/main", by: -1, in: rows) == "origin/main")
        #expect(movedHighlight("gone", by: -1, in: rows) == "origin/main")
        #expect(movedHighlight(nil, by: 1, in: []) == nil)
    }
}
