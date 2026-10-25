import Testing
@testable import Git

@Suite struct GraphLayoutTests {
    private func c(_ hash: String, _ parents: String...) -> Commit { Commit(hash: hash, parents: parents) }
    private func up(_ from: Int, _ to: Int, _ color: Int) -> GraphSegment { GraphSegment(half: .upper, from: from, to: to, color: color) }
    private func down(_ from: Int, _ to: Int, _ color: Int) -> GraphSegment { GraphSegment(half: .lower, from: from, to: to, color: color) }

    @Test func empty() {
        #expect(layoutGraph(commits: []).isEmpty)
    }

    @Test func linear() {
        let rows = layoutGraph(commits: [c("c", "b"), c("b", "a"), c("a")])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.color) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])
        #expect(rows[0].segments == [down(0, 0, 0)])
        #expect(rows[1].segments == [up(0, 0, 0), down(0, 0, 0)])
        #expect(rows[2].segments == [up(0, 0, 0)])
        #expect(rows[0].isBranchTip && !rows[1].isBranchTip)
        #expect(rows[2].isRoot && !rows[0].isRoot)
        #expect(rows.allSatisfy { !$0.isMerge })
    }

    /// main: m = merge(b, f); feat: f off a.
    @Test func branchAndMerge() {
        let rows = layoutGraph(commits: [c("m", "b", "f"), c("f", "a"), c("b", "a"), c("a")])
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows[0].isMerge && rows[0].segments == [down(0, 0, 0), down(0, 1, 1)])
        #expect(rows[0].width == 2)
        #expect(rows[1].color == 1)
        #expect(rows[1].segments == [up(0, 0, 0), up(1, 1, 1), down(0, 0, 0), down(1, 1, 1)])
        // Both rails wait for a: the right one bends into the left, so main stays straight in lane 0.
        #expect(rows[2].segments == [up(0, 0, 0), up(1, 1, 1), down(0, 0, 0), down(1, 0, 1)])
        #expect(rows[2].width == 2)
        #expect(rows[3].segments == [up(0, 0, 0)] && rows[3].isRoot)
    }

    @Test func octopus() {
        let rows = layoutGraph(commits: [c("m", "a", "x", "y"), c("y", "a"), c("x", "a"), c("a")])
        #expect(rows[0].isMerge)
        #expect(rows[0].segments == [down(0, 0, 0), down(0, 1, 1), down(0, 2, 2)])
        #expect(rows[0].width == 3)
        #expect(rows.map(\.lane) == [0, 2, 1, 0])
        #expect(rows[1].segments == [up(0, 0, 0), up(1, 1, 1), up(2, 2, 2), down(0, 0, 0), down(1, 1, 1), down(2, 0, 2)])
        #expect(rows[2].segments == [up(0, 0, 0), up(1, 1, 1), down(0, 0, 0), down(1, 0, 1)])
        #expect(rows[3].segments == [up(0, 0, 0)])
    }

    /// Two tips over a shared base, and two unrelated histories side by side.
    @Test func parallelBranches() {
        let fork = layoutGraph(commits: [c("x", "a"), c("y", "a"), c("a")])
        #expect(fork.map(\.lane) == [0, 1, 0])
        #expect(fork[1].isBranchTip && fork[1].color == 1)
        #expect(fork[1].segments == [up(0, 0, 0), down(0, 0, 0), down(1, 0, 1)])

        let side = layoutGraph(commits: [c("x2", "x1"), c("y2", "y1"), c("x1"), c("y1")])
        #expect(side.map(\.lane) == [0, 1, 0, 1])
        #expect(side[2].isRoot && side[2].segments == [up(0, 0, 0), up(1, 1, 1), down(1, 1, 1)])
        #expect(side[2].width == 2)
        // The freed lane 0 is reused by the next tip instead of growing the graph.
        let reuse = layoutGraph(commits: [c("x1"), c("y2", "y1"), c("z"), c("y1")])
        #expect(reuse.map(\.lane) == [0, 0, 1, 0])
    }

    /// A merge parent another lane already waits for joins that lane; no second rail for the same commit.
    @Test func mergeIntoExistingRail() {
        let rows = layoutGraph(commits: [c("t", "a"), c("m", "b", "a"), c("b", "a"), c("a")])
        #expect(rows.map(\.lane) == [0, 1, 1, 0])
        #expect(rows[1].segments == [up(0, 0, 0), down(0, 0, 0), down(1, 0, 0), down(1, 1, 1)])
        #expect(rows[2].segments == [up(0, 0, 0), up(1, 1, 1), down(0, 0, 0), down(1, 0, 1)])
    }

    /// Paging appends commits: rows already laid out never change, and a parent beyond the page keeps its rail open.
    @Test func stableAcrossPages() {
        let all = [c("m", "b", "f"), c("f", "e"), c("e", "a"), c("b", "a"), c("x", "a"), c("a")]
        let full = layoutGraph(commits: all)
        for n in 1..<all.count {
            #expect(layoutGraph(commits: Array(all.prefix(n))) == Array(full.prefix(n)))
        }
        #expect(layoutGraph(commits: all) == full)
        let page = layoutGraph(commits: Array(all.prefix(2)))
        #expect(page[1].segments.contains(down(1, 1, 1)))
    }
}
