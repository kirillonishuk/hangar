import Foundation
import Git
import Testing
@testable import HangarUI

/// Inspector polish: the Changes badge, log row chips and graph width, row folders, the Search filters toggle.
@MainActor @Suite struct InspectorPolishTests {
    @Test func changesBadgeHiddenAtZeroAndCapped() {
        #expect(segmentBadge(0) == nil)
        #expect(segmentBadge(-1) == nil)
        #expect(segmentBadge(1) == "1")
        #expect(segmentBadge(99) == "99")
        #expect(segmentBadge(100) == "99+")
    }

    @Test func localBranchAbsorbsItsRemoteTwin() {
        let refs = [CommitRef(kind: .branch, name: "fix/panel", isHead: true), CommitRef(kind: .remote, name: "origin/fix/panel")]
        let chips = refChips(refs, limit: 2)
        #expect(chips.shown == [RefChip(ref: refs[0], twin: "origin/fix/panel")])
        #expect(chips.more == 0)
    }

    @Test func remoteWithoutLocalAndTagsStay() {
        let refs = [CommitRef(kind: .remote, name: "origin/main"), CommitRef(kind: .tag, name: "v1")]
        #expect(refChips(refs, limit: 2).shown.map(\.ref) == refs)
        #expect(refChips(refs, limit: 2).more == 0)
    }

    @Test func overflowLeavesTheLastPlaceToPlusK() {
        let refs = [CommitRef(kind: .branch, name: "master", isHead: true), CommitRef(kind: .tag, name: "v5.5.21"),
                    CommitRef(kind: .remote, name: "origin/master"), CommitRef(kind: .branch, name: "test-hangar"),
                    CommitRef(kind: .remote, name: "origin/test-hangar"), CommitRef(kind: .branch, name: "release/v5")]
        // Twins folded: master⇅, v5.5.21, test-hangar⇅, release/v5 — four chips, room for two items.
        let chips = refChips(refs, limit: 2)
        #expect(chips.shown.map(\.ref.name) == ["master"])
        #expect(chips.shown.first?.twin == "origin/master")
        #expect(chips.more == 3)
        // Exactly at the limit: no «+k».
        #expect(refChips(Array(refs.prefix(3)), limit: 2).shown.map(\.ref.name) == ["master", "v5.5.21"])
        #expect(refChips(Array(refs.prefix(3)), limit: 2).more == 0)
    }

    @Test func graphCellIsAsWideAsItsLanes() {
        let t = Theme.GitTab.self
        func c(_ h: String, _ p: String...) -> Commit { Commit(hash: h, parents: p) }
        // A merge: two lanes where the side branch runs, one on the straight line below.
        let rows = layoutGraph(commits: [c("m", "b", "f"), c("f", "a"), c("b", "a"), c("a")])
        #expect(graphWidth(nil) == t.laneX0 * 2)
        #expect(graphWidth(rows[1]) == t.laneX0 * 2 + CGFloat(rows[1].width - 1) * t.laneStep)
        #expect(rows[1].width == 2)
        #expect(graphWidth(rows[3]) == t.laneX0 * 2)
        // Twenty branches open at once: clipped to `maxLanes`.
        let wide = layoutGraph(commits: (0..<20).map { c("t\($0)", "p\($0)") } + (0..<20).map { c("p\($0)", "r") } + [c("r")])
        #expect(graphWidth(wide.max { $0.width < $1.width }) == t.laneX0 * 2 + CGFloat(t.maxLanes - 1) * t.laneStep)
    }

    @Test func folderDroppedWhenTooTight() {
        #expect(folderRoom(width: 200, name: 80, gap: 6, minFolder: 48) == 114)
        #expect(folderRoom(width: 130, name: 80, gap: 6, minFolder: 48) == 0)
        #expect(folderRoom(width: 60, name: 60, gap: 6, minFolder: 48) == 0)
    }

    @Test func changeColumnsFitTheLongestNumbers() {
        let files = [ChangedFile(path: "a", change: .modified, added: 3, deleted: 120), ChangedFile(path: "b", change: .untracked, added: nil, deleted: nil)]
        let c = ChangeColumns(files)
        #expect(c.added == ChangeColumns.width(3))
        #expect(c.deleted == ChangeColumns.width(120))
        #expect(c.deleted > c.added)
        #expect(ChangeColumns([]).added == 0)
    }

    @Test func searchFiltersToggleIsPerSessionAndShowsADot() {
        let model = SearchModel()
        model.launcher = { _, _, _ in nil }
        model.setTarget(SearchTarget(root: "/a"))
        #expect(!model.filtersShown)
        model.filtersShown = true
        #expect(model.filtersShown)
        model.setTarget(SearchTarget(root: "/b"))
        #expect(!model.filtersShown)
        model.setTarget(SearchTarget(root: "/a"))
        #expect(model.filtersShown)
        model.setTarget(SearchTarget(root: "/a", host: "devbox"))
        #expect(!model.filtersShown)

        #expect(!model.filtersActive)
        model.exclude = " , "
        #expect(!model.filtersActive)
        model.exclude = "node_modules"
        #expect(model.filtersActive)
        model.exclude = ""
        model.include = "*.swift"
        #expect(model.filtersActive)
        model.cancel()
    }
}
