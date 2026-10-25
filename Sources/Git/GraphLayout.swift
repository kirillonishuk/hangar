/// One piece of rail in a commit row. `upper`: from the row's top edge at column `from` to the node line at `to`;
/// `lower`: from the node line at `from` to the bottom edge at `to`. Straight when `from == to`.
public struct GraphSegment: Equatable, Sendable {
    public enum Half: Sendable { case upper, lower }
    public var half: Half
    public var from: Int
    public var to: Int
    /// Rail colour index: grows by one per new rail; the UI takes it modulo its palette.
    public var color: Int

    public init(half: Half, from: Int, to: Int, color: Int) {
        self.half = half; self.from = from; self.to = to; self.color = color
    }
}

public struct GraphRow: Equatable, Sendable {
    /// Column of the commit's dot.
    public var lane: Int
    public var color: Int
    /// Sorted: upper before lower, then by `from`, then `to`.
    public var segments: [GraphSegment]
    /// Columns this row spans (above and below the node).
    public var width: Int
    public var isMerge: Bool
    /// Nothing above leads to it: a branch tip.
    public var isBranchTip: Bool
    /// No parents: the rail ends here.
    public var isRoot: Bool
}

/// Lanes for `commits` in log order (children before parents, as `--topo-order` gives). A streaming pass: a row
/// depends only on the commits before it, so appending a page never changes rows already laid out. A parent not in
/// `commits` (next page, filtered history) keeps its rail open to the bottom. Each pending commit has one lane;
/// when two rails wait for the same parent, the right one bends into the left, so the first-parent line stays put.
public func layoutGraph(commits: [Commit]) -> [GraphRow] {
    var lanes: [String?] = []   // the hash each column waits for
    var colors: [Int] = []
    var nextColor = 0
    var rows: [GraphRow] = []
    rows.reserveCapacity(commits.count)

    func freeSlot() -> Int {
        if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
        lanes.append(nil); colors.append(0)
        return lanes.count - 1
    }

    for c in commits {
        let found = lanes.firstIndex(where: { $0 == c.hash })
        let lane: Int
        if let found { lane = found } else {
            lane = freeSlot()
            colors[lane] = nextColor; nextColor += 1
        }
        let color = colors[lane]
        var segs: [GraphSegment] = []
        let before = lanes
        for (j, h) in before.enumerated() where h != nil {
            segs.append(GraphSegment(half: .upper, from: j, to: j, color: colors[j]))
        }
        lanes[lane] = nil
        var touched: Set<Int> = [lane]   // columns whose lower half is already drawn
        for (i, p) in c.parents.enumerated() {
            if let k = lanes.firstIndex(where: { $0 == p }) {
                if i == 0, k > lane {
                    // The parent's rail moves left into this lane.
                    lanes[lane] = p; lanes[k] = nil
                    segs.append(GraphSegment(half: .lower, from: lane, to: lane, color: color))
                    segs.append(GraphSegment(half: .lower, from: k, to: lane, color: colors[k]))
                    colors[lane] = color
                    touched.insert(k)
                } else {
                    segs.append(GraphSegment(half: .lower, from: lane, to: k, color: i == 0 ? color : colors[k]))
                }
            } else if i == 0 {
                lanes[lane] = p
                segs.append(GraphSegment(half: .lower, from: lane, to: lane, color: color))
            } else {
                let k = freeSlot()
                lanes[k] = p; colors[k] = nextColor; nextColor += 1
                touched.insert(k)
                segs.append(GraphSegment(half: .lower, from: lane, to: k, color: colors[k]))
            }
        }
        for (j, h) in before.enumerated() where h != nil && !touched.contains(j) && lanes[j] == h {
            segs.append(GraphSegment(half: .lower, from: j, to: j, color: colors[j]))
        }
        segs.sort { a, b in
            if a.half != b.half { return a.half == .upper }
            return (a.from, a.to) < (b.from, b.to)
        }
        while let last = lanes.last, last == nil { lanes.removeLast(); colors.removeLast() }
        rows.append(GraphRow(lane: lane, color: color, segments: segs, width: max(before.count, lanes.count, lane + 1),
                             isMerge: c.parents.count > 1, isBranchTip: found == nil, isRoot: c.parents.isEmpty))
    }
    return rows
}
