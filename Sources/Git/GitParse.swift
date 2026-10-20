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

// MARK: Changes and diff

public enum DiffMode: Hashable, Sendable {
    case base(String)
    case uncommitted
}

public struct ChangedFile: Identifiable, Sendable, Equatable {
    public var path: String
    public var origPath: String?
    public var change: FileChange
    /// nil: binary or untracked.
    public var added: Int?
    public var deleted: Int?
    public var id: String { path }

    public init(path: String, origPath: String? = nil, change: FileChange, added: Int? = nil, deleted: Int? = nil) {
        self.path = path; self.origPath = origPath; self.change = change; self.added = added; self.deleted = deleted
    }
}

public struct ChangeSet: Sendable, Equatable {
    public var files: [ChangedFile]
    /// sha of the merge-base, `HEAD`, or the empty tree when there are no commits.
    public var from: String
    /// Effective mode (after falling back).
    public var mode: DiffMode
    public var baseMissing: Bool
    public var truncated: Bool
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case context, added, deleted }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    public var noNewlineAtEnd: Bool
}

public struct Hunk: Sendable, Equatable {
    /// The whole `@@ … @@ ctx` line.
    public var header: String
    public var oldStart: Int
    public var newStart: Int
    public var lines: [DiffLine]
}

public enum FileDiff: Sendable, Equatable {
    case text(hunks: [Hunk], oldMode: String?, newMode: String?)
    case binary
    case tooLarge(lines: Int)
    case notAFile
}

/// `--name-status -z --find-renames`: `M\0path\0`, `R100\0old\0new\0`.
func parseNameStatus(_ out: String) -> [ChangedFile] {
    let f = out.split(separator: "\0", omittingEmptySubsequences: true)
    var files: [ChangedFile] = []
    var i = 0
    while i < f.count {
        let code = f[i]; i += 1
        guard let c = code.first else { continue }
        let isPair = c == "R" || c == "C"
        guard i + (isPair ? 1 : 0) < f.count else { break }
        let first = String(f[i]); i += 1
        switch c {
        case "R":
            let new = String(f[i]); i += 1
            files.append(ChangedFile(path: new, origPath: first, change: .renamed))
        case "C":
            let new = String(f[i]); i += 1
            files.append(ChangedFile(path: new, change: .added))
        case "A": files.append(ChangedFile(path: first, change: .added))
        case "D": files.append(ChangedFile(path: first, change: .deleted))
        case "U": files.append(ChangedFile(path: first, change: .conflicted))
        default: files.append(ChangedFile(path: first, change: .modified))
        }
    }
    return files
}

struct NumstatEntry: Equatable { var path: String; var added: Int?; var deleted: Int? }

/// `--numstat -z`: `a\td\tpath\0`, renames `a\td\t\0old\0new\0`; binary is `-\t-`.
func parseNumstat(_ out: String) -> [NumstatEntry] {
    let f = out.split(separator: "\0", omittingEmptySubsequences: false)
    var res: [NumstatEntry] = []
    var i = 0
    while i < f.count {
        let rec = f[i]; i += 1
        let p = rec.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard p.count == 3 else { continue }
        var path = String(p[2])
        if path.isEmpty {
            guard i + 1 < f.count else { break }
            path = String(f[i + 1]); i += 2
        }
        res.append(NumstatEntry(path: path, added: Int(p[0]), deleted: Int(p[1])))
    }
    return res
}

/// Reads each hunk strictly by the counts in its header, so content lines that look like
/// `diff --git`, `@@` or `+++` are content.
func parseUnifiedDiff(_ out: String) -> FileDiff {
    // Split on "\n" scalars: a Character-based split would glue "\r\n" together.
    let lines = out.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    var hunks: [Hunk] = []
    var oldMode: String?, newMode: String?
    var i = 0
    while i < lines.count {
        let l = lines[i]; i += 1
        if let m = l.wholeMatch(of: /^(old|new) mode (\d+)$/) {
            if m.1 == "old" { oldMode = String(m.2) } else { newMode = String(m.2) }
        } else if let m = l.wholeMatch(of: /^new file mode (\d+)$/) {
            newMode = String(m.1)
        } else if let m = l.wholeMatch(of: /^deleted file mode (\d+)$/) {
            oldMode = String(m.1)
        } else if l.hasPrefix("Binary files ") || l.hasPrefix("GIT binary patch") {
            return .binary
        } else if let m = l.prefixMatch(of: /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) {
            var oldLeft = m.2.flatMap { Int($0) } ?? 1
            var newLeft = m.4.flatMap { Int($0) } ?? 1
            var oldNo = Int(m.1) ?? 0, newNo = Int(m.3) ?? 0
            var hl: [DiffLine] = []
            let hunk = Hunk(header: l, oldStart: oldNo, newStart: newNo, lines: [])
            while i < lines.count {
                let s = lines[i]
                let prefix = s.unicodeScalars.first  // scalars: a combining mark after the prefix must stay in the text
                if prefix == "\\" {
                    if !hl.isEmpty { hl[hl.count - 1].noNewlineAtEnd = true }
                    i += 1; continue
                }
                guard oldLeft > 0 || newLeft > 0 else { break }
                i += 1
                let text = String(s.unicodeScalars.dropFirst())
                switch prefix {
                case "-" where oldLeft > 0:
                    hl.append(DiffLine(kind: .deleted, text: text, oldLine: oldNo, newLine: nil, noNewlineAtEnd: false))
                    oldNo += 1; oldLeft -= 1
                case "+" where newLeft > 0:
                    hl.append(DiffLine(kind: .added, text: text, oldLine: nil, newLine: newNo, noNewlineAtEnd: false))
                    newNo += 1; newLeft -= 1
                default: // " " (or an empty line whose trailing space was stripped)
                    guard oldLeft > 0 && newLeft > 0 else { i -= 1; oldLeft = 0; newLeft = 0; continue }
                    hl.append(DiffLine(kind: .context, text: text, oldLine: oldNo, newLine: newNo, noNewlineAtEnd: false))
                    oldNo += 1; newNo += 1; oldLeft -= 1; newLeft -= 1
                }
            }
            hunks.append(Hunk(header: hunk.header, oldStart: hunk.oldStart, newStart: hunk.newStart, lines: hl))
        }
    }
    return .text(hunks: hunks, oldMode: oldMode, newMode: newMode)
}
