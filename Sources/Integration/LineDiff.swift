public enum DiffLine: Equatable, Sendable {
    case same(String), added(String), removed(String), skipped(Int)
}

private let noNewlineMarker = "\\ No newline at end of file"

private func lines(_ s: String, marking: Bool) -> [String] {
    var l = s.components(separatedBy: "\n")
    if l.last == "" { l.removeLast() } else if marking { l.append(noNewlineMarker) }
    return l
}

/// LCS line diff; removals come before additions at a change. Settings files are small, so O(n·m) is fine.
public func lineDiff(_ old: String, _ new: String) -> [DiffLine] {
    // A trailing-newline-only change must show: mark the side without the final newline, only when the sides differ in that.
    let marking = old.hasSuffix("\n") != new.hasSuffix("\n")
    let a = lines(old, marking: marking), b = lines(new, marking: marking)
    var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
        }
    }
    var out: [DiffLine] = []
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, j < b.count, a[i] == b[j] {
            out.append(.same(a[i])); i += 1; j += 1
        } else if j == b.count || (i < a.count && lcs[i + 1][j] >= lcs[i][j + 1]) {
            out.append(.removed(a[i])); i += 1
        } else {
            out.append(.added(b[j])); j += 1
        }
    }
    return out
}

/// Runs of `same` longer than 2·context become `skipped(n)`, keeping `context` lines next to each change.
public func collapsed(_ diff: [DiffLine], context: Int = 3) -> [DiffLine] {
    var out: [DiffLine] = []
    var k = 0
    while k < diff.count {
        guard case .same = diff[k] else { out.append(diff[k]); k += 1; continue }
        var end = k
        while end < diff.count, case .same = diff[end] { end += 1 }
        let run = diff[k..<end]
        if run.count > 2 * context {
            let head = k == 0 ? 0 : context, tail = end == diff.count ? 0 : context
            out += run.prefix(head)
            out.append(.skipped(run.count - head - tail))
            out += run.suffix(tail)
        } else {
            out += run
        }
        k = end
    }
    return out
}
