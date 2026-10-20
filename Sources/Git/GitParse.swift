import Foundation

/// Badge letter is the raw value.
public enum FileChange: String, Sendable, Equatable {
    case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", conflicted = "U"
}

public struct StatusEntry: Sendable, Equatable, Hashable {
    public var path: String
    public var origPath: String?
    public var change: FileChange

    public init(path: String, origPath: String? = nil, change: FileChange) {
        self.path = path
        self.origPath = origPath
        self.change = change
    }
}

public struct StatusResult: Sendable, Equatable {
    public var entries: [StatusEntry]
    public var truncated: Bool
}

public struct FileListing: Sendable, Equatable {
    public var paths: [String]
    public var truncated: Bool
}

/// Parses `status --porcelain=v2 -z`. Paths are relative to the repository root.
func parseStatusV2(_ out: String, limit: Int) -> StatusResult {
    let fields = out.split(separator: "\0", omittingEmptySubsequences: true)
    var entries: [StatusEntry] = []
    var truncated = false
    var i = 0
    while i < fields.count {
        let f = fields[i]
        i += 1
        guard let kind = f.first else { continue }
        let entry: StatusEntry
        switch kind {
        case "1": // 1 XY sub mH mI mW hH hI path
            let p = f.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
            guard p.count == 9 else { continue }
            let xy = p[1]
            let change: FileChange = xy.contains("D") ? .deleted : xy.first == "A" ? .added : .modified
            entry = StatusEntry(path: String(p[8]), change: change)
        case "2": // 2 XY sub mH mI mW hH hI Xscore path, then origPath as the next field
            let p = f.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
            guard p.count == 10 else { continue }
            let orig = i < fields.count ? String(fields[i]) : nil
            i += 1
            entry = StatusEntry(path: String(p[9]), origPath: orig, change: .renamed)
        case "u": // u XY sub m1 m2 m3 mW h1 h2 h3 path
            let p = f.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
            guard p.count == 11 else { continue }
            entry = StatusEntry(path: String(p[10]), change: .conflicted)
        case "?":
            entry = StatusEntry(path: String(f.dropFirst(2)), change: .untracked)
        default: // "#" headers, "!" ignored
            continue
        }
        if entries.count == limit { truncated = true; break }
        entries.append(entry)
    }
    return StatusResult(entries: entries, truncated: truncated)
}
