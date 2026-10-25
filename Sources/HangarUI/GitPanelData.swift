import CoreServices
import Foundation
import Git

// Pure pieces of the Git tab (redesign v1 §4): the query, the branch tree, dates, commit files, refresh triggers.

struct GitAuthor: Hashable, Sendable {
    var name: String
    var email: String
}

/// The Date chip: today, or today and the 6 / 29 days before.
enum GitDateRange: CaseIterable, Sendable {
    case today, week, month

    var daysBack: Int {
        switch self {
        case .today: 0
        case .week: 6
        case .month: 29
        }
    }
}

/// What the user asked the log for: the Branch chip (or a click in the branch tree), the search field, the chips.
struct GitQuery: Equatable {
    var scope: LogFilters.Scope = .head
    var text = ""
    var author: GitAuthor?
    var date: GitDateRange?
    var path: String?

    /// `./src/` → `src`; blank or `.` → nil (the whole folder).
    static func normalizedPath(_ path: String?) -> String? {
        guard var p = path?.trimmingCharacters(in: .whitespaces) else { return nil }
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty || p == "." ? nil : p
    }

    private var trimmedText: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// `since` is local midnight of the first day; the author is matched by `<email>` (one person, not a name prefix).
    func filters(now: Date, calendar: Calendar = .current) -> LogFilters {
        var f = LogFilters(ref: scope)
        f.text = trimmedText
        if let author { f.author = author.email.isEmpty ? author.name : "<\(author.email)>" }
        if let date {
            f.since = calendar.date(byAdding: .day, value: -date.daysBack, to: calendar.startOfDay(for: now))
        }
        f.path = Self.normalizedPath(path)
        return f
    }

    /// Text, author, date and path cut holes in the history: lanes between the hits would lie (the API's advice).
    var hidesGraph: Bool { activeCount > 0 }

    /// Active chips besides the branch (and the search text).
    var activeCount: Int {
        [trimmedText != nil, author != nil, date != nil, Self.normalizedPath(path) != nil].filter { $0 }.count
    }
}

// MARK: Branch tree

/// A branch or a folder of branches sharing a `/` prefix (`feat/…`); remote branches group by remote first.
struct BranchNode: Equatable, Identifiable {
    /// `<section>/<full name>` for a branch, `<section>/<prefix>/` for a folder.
    var id: String
    /// The last path component (a folder: its own component).
    var name: String
    var branch: BranchInfo?
    var children: [BranchNode] = []
    /// Branches inside (1 for a branch).
    var count: Int
}

/// Branches before folders, each by name.
func branchTree(_ branches: [BranchInfo], id section: String) -> [BranchNode] {
    func build(_ items: [(rest: [Substring], info: BranchInfo)], prefix: String) -> [BranchNode] {
        var leaves: [BranchNode] = []
        var folders: [String: [(rest: [Substring], info: BranchInfo)]] = [:]
        for item in items {
            if item.rest.count == 1 {
                leaves.append(BranchNode(id: section + "/" + item.info.name, name: String(item.rest[0]), branch: item.info, count: 1))
            } else {
                folders[String(item.rest[0]), default: []].append((Array(item.rest.dropFirst()), item.info))
            }
        }
        let byName: (BranchNode, BranchNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let dirs = folders.map { name, items -> BranchNode in
            let p = prefix + name + "/"
            let children = build(items, prefix: p)
            return BranchNode(id: section + "/" + p, name: name, children: children, count: children.reduce(0) { $0 + $1.count })
        }
        return leaves.sorted(by: byName) + dirs.sorted(by: byName)
    }
    return build(branches.map { ($0.name.split(separator: "/", omittingEmptySubsequences: false), $0) }, prefix: "")
}

/// One visible line of the branch block.
struct BranchRowItem: Equatable, Identifiable {
    enum Kind: Equatable { case head, section, folder, branch }
    var id: String
    var kind: Kind
    var depth: Int
    var title: String
    /// Sections and folders: branches inside.
    var count: Int?
    var branch: BranchInfo?
    var expanded = false

    /// What a click filters the log to (sections and folders toggle instead).
    var scope: LogFilters.Scope? {
        switch kind {
        case .head: .head
        case .branch: branch.map { .ref($0.name) }
        case .section, .folder: nil
        }
    }
}

/// HEAD, then Local and Remote (only when they have branches), folders open when their id is in `expanded`.
@MainActor func branchRows(_ list: BranchList, expanded: Set<String>) -> [BranchRowItem] {
    let head = list.head.branch ?? list.head.hash.map { String($0.prefix(7)) } ?? "HEAD"
    var rows = [BranchRowItem(id: "head", kind: .head, depth: 0, title: head)]
    func add(_ nodes: [BranchNode], depth: Int) {
        for n in nodes {
            if n.branch != nil {
                rows.append(BranchRowItem(id: n.id, kind: .branch, depth: depth, title: n.name, branch: n.branch))
            } else {
                let open = expanded.contains(n.id)
                rows.append(BranchRowItem(id: n.id, kind: .folder, depth: depth, title: n.name, count: n.count, expanded: open))
                if open { add(n.children, depth: depth + 1) }
            }
        }
    }
    for (id, title, branches) in [("local", L10n.gitLocal, list.local), ("remote", L10n.gitRemote, list.remote)] where !branches.isEmpty {
        let open = expanded.contains(id)
        rows.append(BranchRowItem(id: id, kind: .section, depth: 0, title: title, count: branches.count, expanded: open))
        if open { add(branchTree(branches, id: id), depth: 1) }
    }
    return rows
}

// MARK: Dates

/// Formatters per language and time zone (building one per row would cost more than the row).
@MainActor private enum GitDateFormat {
    static var cache: [String: DateFormatter] = [:]

    static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let lang = L10n.resolve(L10n.language).rawValue
        let key = lang + "|" + calendar.timeZone.identifier + "|" + format
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: lang)
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        cache[key] = f
        return f
    }

    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        let en = L10n.resolve(L10n.language) == .en
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let format = en ? (sameYear ? "MMM d" : "MMM d, yyyy") : (sameYear ? "d MMM" : "d MMM yyyy")
        // «окт.» → «окт», as in the mockup.
        return formatter(format, calendar).string(from: date).replacingOccurrences(of: ".", with: "")
    }
}

private enum GitDay { case today, yesterday, earlier }

private func gitDay(_ date: Date, now: Date, calendar: Calendar) -> GitDay {
    let today = calendar.startOfDay(for: now)
    if date >= today { return .today }  // a commit from the future (skewed clock) is still "today"
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
    return .earlier
}

/// The log row's date: `16:03` today, «вчера», `23 окт`, `2 мар 2025`.
@MainActor func gitShortDate(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    switch gitDay(date, now: now, calendar: calendar) {
    case .today: GitDateFormat.formatter("HH:mm", calendar).string(from: date)
    case .yesterday: L10n.gitYesterday
    case .earlier: GitDateFormat.day(date, now: now, calendar: calendar)
    }
}

/// The details' date: «сегодня 16:03», «вчера 16:03», «23 окт 16:03».
@MainActor func gitLongDate(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    let time = GitDateFormat.formatter("HH:mm", calendar).string(from: date)
    switch gitDay(date, now: now, calendar: calendar) {
    case .today: return L10n.gitTodayAt(time)
    case .yesterday: return L10n.gitYesterdayAt(time)
    case .earlier: return GitDateFormat.day(date, now: now, calendar: calendar) + " " + time
    }
}

// MARK: Commit files

/// Files of a commit under one folder (`""`: the top level).
struct CommitFileGroup: Equatable, Identifiable {
    var dir: String
    var files: [ChangedFile]
    var added: Int
    var deleted: Int
    var id: String { dir }
}

/// Top-level files first, then one group per folder by path; files by name. Binary files count 0.
func commitFileGroups(_ files: [ChangedFile]) -> [CommitFileGroup] {
    var byDir: [String: [ChangedFile]] = [:]
    for f in files { byDir[(f.path as NSString).deletingLastPathComponent, default: []].append(f) }
    let name: (ChangedFile) -> String = { ($0.path as NSString).lastPathComponent }
    return byDir.keys.sorted { a, b in a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending }.map { dir in
        let list = byDir[dir]!.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        let t = commitFileTotals(list)
        return CommitFileGroup(dir: dir, files: list, added: t.added, deleted: t.deleted)
    }
}

func commitFileTotals(_ files: [ChangedFile]) -> (added: Int, deleted: Int) {
    (files.reduce(0) { $0 + ($1.added ?? 0) }, files.reduce(0) { $0 + ($1.deleted ?? 0) })
}

// MARK: Refresh trigger

extension RefreshParts {
    /// HEAD or a ref moved (commit, checkout, fetch): the Git tab reloads; the inspector itself ignores it.
    static let refs = RefreshParts(rawValue: 8)
}

/// FSEvents that move HEAD or a ref: in the git dir (`HEAD`, `refs/…`, `packed-refs`) or the common dir of a
/// worktree; a dropped or coalesced stream may hide one. Lock files are git still writing.
func refsMoved(_ events: [FSEvent], gitDir: String?, commonDir: String?) -> Bool {
    guard gitDir != nil else { return false }
    let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped)
    for (path, flags) in events {
        if flags & rescan != 0 { return true }
        for dir in [gitDir, commonDir].compactMap({ $0 }) where path.hasPrefix(dir + "/") {
            let rel = path.dropFirst(dir.count + 1)
            let first = rel.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if !rel.hasSuffix(".lock"), ["HEAD", "refs", "packed-refs"].contains(first) { return true }
        }
    }
    return false
}

// MARK: Path chip

/// The Path chip's picks from the Files tree already loaded (no disk access): folders and files whose path contains
/// `query` (case-insensitive), shallow first, at most `limit`; a blank query lists the top level.
func gitPathCandidates(_ tree: FileTree, query: String, limit: Int) -> [FileTree.Entry] {
    let q = query.trimmingCharacters(in: .whitespaces)
    var out: [FileTree.Entry] = []
    var queue = [""]
    var i = 0
    while i < queue.count, out.count < limit {
        for e in tree.children(of: queue[i]) ?? [] {
            if e.isDir, !q.isEmpty { queue.append(e.path) }
            if q.isEmpty || e.path.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                out.append(e)
                if out.count == limit { break }
            }
        }
        i += 1
    }
    return out
}
