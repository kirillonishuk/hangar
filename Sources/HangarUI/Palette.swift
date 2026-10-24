import Foundation

/// ⌘P quick open / ⇧⌘P command palette logic (decision #NN-palette): fuzzy matching and ranking, no UI.

/// Score (higher is better) and the matched character offsets of `text`, for highlighting.
struct FuzzyMatch: Equatable {
    var score: Int
    var positions: [Int]
}

/// Case-insensitive subsequence match; spaces in the query are ignored. Word starts (after a separator, camelCase,
/// the very start) and runs of consecutive characters score higher; gaps and a late first match cost a little.
func fuzzyMatch(_ query: String, _ text: String) -> FuzzyMatch? {
    let q = query.filter { !$0.isWhitespace }.map { String($0).lowercased() }
    guard !q.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
    let raw = Array(text)
    let t = raw.map { String($0).lowercased() }
    func wordStart(_ i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = raw[i - 1], cur = raw[i]
        return !(prev.isLetter || prev.isNumber) || (cur.isUppercase && prev.isLowercase)
    }
    // Can q[qi...] still be found in t[ti...]?
    func fits(_ qi: Int, _ ti: Int) -> Bool {
        var j = ti
        for c in q[qi...] {
            while j < t.count, t[j] != c { j += 1 }
            if j == t.count { return false }
            j += 1
        }
        return true
    }
    var positions: [Int] = []
    var score = 0
    var ti = 0
    for (qi, c) in q.enumerated() {
        let prev = positions.last
        var pick: Int
        if prev != nil, ti < t.count, t[ti] == c {
            pick = ti  // consecutive: keep the run
            score += 1 + 5
        } else {
            guard let first = t[ti...].firstIndex(of: c) else { return nil }
            pick = first
            if !wordStart(first),
               let ws = t.indices.dropFirst(first + 1).first(where: { t[$0] == c && wordStart($0) && fits(qi + 1, $0 + 1) }) {
                pick = ws
            }
            score += 1 + (pick == 0 ? 10 : wordStart(pick) ? 8 : 0)
            if let prev { score -= min(pick - prev - 1, 3) } else { score -= min(pick, 5) }
        }
        positions.append(pick)
        ti = pick + 1
    }
    return FuzzyMatch(score: score, positions: positions)
}

struct PaletteItem: Equatable, Identifiable {
    enum Kind: Equatable { case task, file, command }
    enum Target: Equatable { case task(UUID), file(String), command(Shortcut) }

    let target: Target
    /// Shown and matched: task name, file name, command title.
    let title: String
    /// Project of a task, directory of a file.
    var subtitle = ""
    /// Matched offsets in `title` (set by ranking).
    var positions: [Int] = []

    init(task: UUID, name: String, project: String) { target = .task(task); title = name; subtitle = project }
    init(file path: String) {
        target = .file(path)
        let slash = path.lastIndex(of: "/")
        title = slash.map { String(path[path.index(after: $0)...]) } ?? path
        subtitle = slash.map { String(path[..<$0]) } ?? ""
    }
    init(command: Shortcut, title: String) { target = .command(command); self.title = title }

    var kind: Kind {
        switch target {
        case .task: .task
        case .file: .file
        case .command: .command
        }
    }

    var id: String {
        switch target {
        case .task(let id): "t:" + id.uuidString
        case .file(let path): "f:" + path
        case .command(let sc): "c:\(sc)"
        }
    }
}

struct PaletteSection: Equatable {
    var kind: PaletteItem.Kind
    var items: [PaletteItem]
}

/// Rows per section; the list scrolls, the rest is reachable by typing more.
let paletteSectionLimit = 50
/// Files of the task (the energy budget of matching per keystroke): from the inspector's tree, or one capped `ls-files`.
let paletteFileCap = 5000

/// Commands: every menu action of the shortcut table (tabs 1…9 and split focus are not commands, the palette not itself).
var paletteCommands: [Shortcut] {
    [.newTask, .addProject, .newTab, .closeTab, .splitRight, .splitDown, .archiveTask, .rename,
     .prevTask, .nextTask, .prevTab, .nextTab, .toggleSidebar, .toggleInspector, .inspectorFiles, .inspectorChanges,
     .toggleDrawer, .limits, .revealInFinder, .copyPath, .settings]
}

/// Files of the inspector's already loaded tree, shallow first, at most `cap` (no disk access).
func paletteFiles(_ tree: FileTree, cap: Int = paletteFileCap) -> [String] {
    var out: [String] = []
    var queue = [""]
    var i = 0
    while i < queue.count, out.count < cap {
        for entry in tree.children(of: queue[i]) ?? [] {
            if entry.isDir { queue.append(entry.path) } else if entry.opensInEditor, out.count < cap { out.append(entry.path) }
        }
        i += 1
    }
    return out
}

/// A leading `>` switches to commands (as in VS Code's ⌘P); the rest is the query.
func paletteCommandQuery(_ query: String) -> String? {
    query.first == ">" ? String(query.dropFirst()) : nil
}

/// Quick open: tasks, then files — tasks as given without a query, files once something is typed.
/// `>…`: commands only, as given without a query. With a query: matches by score (ties: shorter title, then given order).
func paletteSections(query: String, tasks: [PaletteItem], files: [String], commands: [PaletteItem]) -> [PaletteSection] {
    func ranked(_ items: [PaletteItem], _ query: String, _ match: (PaletteItem) -> FuzzyMatch?) -> [PaletteItem] {
        guard !query.allSatisfy(\.isWhitespace) else { return Array(items.prefix(paletteSectionLimit)) }
        let scored = items.enumerated().compactMap { i, item -> (Int, Int, PaletteItem)? in
            guard let m = match(item) else { return nil }
            var item = item
            item.positions = m.positions
            return (m.score, i, item)
        }
        return scored.sorted { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if a.2.title.count != b.2.title.count { return a.2.title.count < b.2.title.count }
            return a.1 < b.1
        }.prefix(paletteSectionLimit).map(\.2)
    }
    var out: [PaletteSection] = []
    func add(_ kind: PaletteItem.Kind, _ items: [PaletteItem]) {
        if !items.isEmpty { out.append(PaletteSection(kind: kind, items: items)) }
    }
    if let q = paletteCommandQuery(query) {
        add(.command, ranked(commands, q) { fuzzyMatch(q, $0.title) })
        return out
    }
    add(.task, ranked(tasks, query) { item in
        // The project name finds its tasks too, a little below a match in the name itself.
        fuzzyMatch(query, item.title) ?? fuzzyMatch(query, item.subtitle).map { FuzzyMatch(score: $0.score - 5, positions: []) }
    })
    if !query.allSatisfy(\.isWhitespace) {
        add(.file, ranked(files.map(PaletteItem.init(file:)), query) { item in
            // The file name first; a match only across the directories ranks below any name match.
            if let m = fuzzyMatch(query, item.title) { return FuzzyMatch(score: m.score + 20, positions: m.positions) }
            guard case .file(let path) = item.target else { return nil }
            return fuzzyMatch(query, path).map { FuzzyMatch(score: $0.score, positions: []) }
        })
    }
    return out
}
