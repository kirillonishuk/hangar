import Foundation

/// Directory index of the inspector's Files view: git builds it from one `ls-files` at once, a plain folder
/// fills it a directory at a time (`setChildren`). Dirs first, then `localizedStandardCompare`.
struct FileTree: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var name: String
        /// From the root, `/`-separated.
        var path: String
        var isDir: Bool
        /// A symlink to a directory: shown, but neither expandable (loops) nor an editor file.
        var isDirLink = false
        var opensInEditor: Bool { !isDir && !isDirLink }
    }

    /// Loaded directories ("" = root) → sorted children.
    private var dirs: [String: [Entry]] = [:]

    init() {}

    /// Runs off the main thread (up to 200 000 paths). `dirLinks`: paths that are symlinks to a directory.
    init(paths: [String], dirLinks: Set<String> = []) {
        var children: [String: [String: Bool]] = [:]  // dir → name → isDir
        for path in paths {
            var parent = ""
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            for (i, part) in parts.enumerated() {
                let isDir = i < parts.count - 1
                let name = String(part)
                if isDir || children[parent]?[name] == nil { children[parent, default: [:]][name] = isDir }
                if !isDir { break }
                parent = parent.isEmpty ? name : parent + "/" + name
            }
        }
        for (dir, names) in children {
            dirs[dir] = Self.sorted(names.map { name, isDir in
                let path = dir.isEmpty ? name : dir + "/" + name
                return Entry(name: name, path: path, isDir: isDir, isDirLink: !isDir && dirLinks.contains(path))
            })
        }
    }

    /// nil — the directory is not loaded (or is not a directory).
    func children(of dir: String) -> [Entry]? { dirs[dir] }

    /// Plain folders: `entries` from `listDirectory`; their paths are rebased under `dir`.
    mutating func setChildren(_ entries: [Entry], of dir: String) {
        dirs[dir] = Self.sorted(entries.map { Entry(name: $0.name, path: dir.isEmpty ? $0.name : dir + "/" + $0.name, isDir: $0.isDir, isDirLink: $0.isDirLink) })
    }

    /// Entries in all loaded directories.
    var count: Int { dirs.values.reduce(0) { $0 + $1.count } }

    /// shortcut: `localizedStandardCompare` is slow-ish (ICU); fine for one directory, a 200 000-path listing sorts in well under a second off-main.
    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

struct TreeRow: Identifiable, Equatable {
    var entry: FileTree.Entry
    var depth: Int
    var expanded: Bool
    var id: String { entry.path }
}

/// Rows of the root plus every expanded directory whose children are loaded.
func visibleRows(_ tree: FileTree, expanded: Set<String>) -> [TreeRow] {
    var rows: [TreeRow] = []
    func walk(_ dir: String, _ depth: Int) {
        for entry in tree.children(of: dir) ?? [] {
            let open = entry.isDir && expanded.contains(entry.path)
            rows.append(TreeRow(entry: entry, depth: depth, expanded: open))
            if open { walk(entry.path, depth + 1) }
        }
    }
    walk("", 0)
    return rows
}

/// Ancestors of the first 50 changed paths; a huge tree (≥ 50 000 paths) opens nothing by itself.
func autoExpanded(for changes: [String], fileCount: Int) -> Set<String> {
    guard fileCount < 50_000 else { return [] }
    var dirs = Set<String>()
    for path in changes.prefix(50) {
        var parts = path.split(separator: "/").dropLast()
        while !parts.isEmpty {
            dirs.insert(parts.joined(separator: "/"))
            parts.removeLast()
        }
    }
    return dirs
}

/// One directory of a plain (non-git) folder; paths are names (`setChildren` rebases them).
/// shortcut: local FileManager, stage 6 goes through Exec.
nonisolated func listDirectory(_ url: URL) -> [FileTree.Entry] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
    return urls.compactMap { u in
        let name = u.lastPathComponent
        guard name != ".git", name != ".DS_Store" else { return nil }
        let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            // Never followed (a link to a parent would loop); a link to a directory is a dead-end row.
            var target: ObjCBool = false
            let toDir = FileManager.default.fileExists(atPath: u.path, isDirectory: &target) && target.boolValue
            return FileTree.Entry(name: name, path: name, isDir: false, isDirLink: toDir)
        }
        return FileTree.Entry(name: name, path: name, isDir: values?.isDirectory == true)
    }
}
