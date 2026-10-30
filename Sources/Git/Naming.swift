import Foundation

private let translit: [Character: String] = [
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
    "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
    "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y",
    "ь": "", "э": "e", "ю": "yu", "я": "ya",
]

/// Task name -> git branch name: transliterated, lowercase, only `[a-z0-9._]` and single `-`; always passes
/// `git check-ref-format --branch`. Distinct names may share a slug: the caller resolves collisions.
public func branchSlug(_ name: String) -> String {
    var latin = ""
    for ch in name.lowercased() {
        if let t = translit[ch] { latin += t; continue }
        let s = String(ch)
        latin += s.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? s
    }
    var out = ""
    for u in latin.lowercased().unicodeScalars {
        let ok = (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || u == "." || u == "_"
        let c: Character = ok ? Character(u) : "-"
        if c == out.last, c == "-" || c == "." { continue }
        out.append(c)
    }
    let edges = CharacterSet(charactersIn: "-.")
    var trimmed = out.trimmingCharacters(in: edges)
    while trimmed.hasSuffix(".lock") {
        trimmed = String(trimmed.dropLast(5)).trimmingCharacters(in: edges)
    }
    return trimmed.isEmpty ? "task" : trimmed
}

/// A name to use as the branch verbatim: only `[A-Za-z0-9._/-]` (so no space, control, `~^:?*[\\`, `@{`, and nothing a
/// shell or URL quotes), plus the rest of `git check-ref-format --branch` rules, in Swift since it runs per keystroke.
/// shortcut: other characters git accepts (Cyrillic, `!`, `@`) still give the slug; widen if users ask.
public func isBranchName(_ name: String) -> Bool {
    guard !name.isEmpty, name != "HEAD", !name.hasPrefix("-"), !name.hasSuffix("."), !name.contains("..") else { return false }
    guard name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        || "._/-".unicodeScalars.contains($0) }) else { return false }
    return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
    }
}

/// Default: `<dirname>/<basename>.worktrees/<slug>`; with `root`: `<root>/<slug>`.
public func worktreePath(projectPath: String, root: String?, branch: String) -> String {
    let base = root.map(trimmedPath) ?? defaultWorktreeRoot(projectPath: projectPath)
    return (base == "/" ? "" : base) + "/" + branchSlug(branch)
}

/// The folder all of a project's copies go to by default: next to it, `<dirname>/<basename>.worktrees`, never inside
/// (editors watch everything under the project). String-only, no stat or symlink resolution: the path may be on a server.
/// shortcut: a project at `/` has no "next to"; it gets `/.worktrees`.
public func defaultWorktreeRoot(projectPath: String) -> String {
    let p = trimmedPath(projectPath)
    guard p != "/", let slash = p.lastIndex(of: "/") else { return p == "/" ? "/.worktrees" : p + ".worktrees" }
    return String(p[..<slash]) + "/" + p[p.index(after: slash)...] + ".worktrees"
}

/// True if `root` is the project folder or lies inside it: copies there show up in the project's own tree and its
/// editors' file watchers. `local`: `~` expanded, symlinks resolved (the root may not exist yet) and case ignored on a
/// case-insensitive volume; a server's path is compared as typed.
public func worktreeRootInsideProject(_ root: String, project: String, local: Bool = true) -> Bool {
    func prepared(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return local ? lexicalPath(resolvedPath(lexicalPath((p as NSString).expandingTildeInPath))) : lexicalPath(p)
    }
    var r = prepared(root), p = prepared(project)
    guard !r.isEmpty, !p.isEmpty else { return false }
    if local, !caseSensitiveVolume(p) { r = r.lowercased(); p = p.lowercased() }
    return r == p || r.hasPrefix(p == "/" ? "/" : p + "/")
}

/// `.`, `..`, repeated and trailing slashes folded as text (no stat, no symlinks: the path may be on a server or not exist yet).
/// `..` above `/` stays at `/`; a relative path keeps its leading `..`.
public func lexicalPath(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    var parts: [Substring] = []
    for c in path.split(separator: "/") where c != "." {
        if c == "..", let last = parts.last, last != ".." { parts.removeLast() }
        else if c == "..", absolute { continue }
        else { parts.append(c) }
    }
    let joined = parts.joined(separator: "/")
    return absolute ? "/" + joined : (joined.isEmpty ? "." : joined)
}

private func trimmedPath(_ path: String) -> String {
    var p = path
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    return p
}

/// `realpath` of the longest existing prefix plus the rest as written.
private func resolvedPath(_ path: String) -> String {
    guard path.hasPrefix("/") else { return path }
    var head = trimmedPath(path), tail: [String] = []
    while head != "/", !FileManager.default.fileExists(atPath: head) {
        tail.insert((head as NSString).lastPathComponent, at: 0)
        head = (head as NSString).deletingLastPathComponent
    }
    guard let real = realpath(head, nil) else { return path }
    defer { free(real) }
    return ([String(cString: real)] + tail).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
}

private func caseSensitiveVolume(_ path: String) -> Bool {
    var url = URL(fileURLWithPath: path)
    while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
    return (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? true
}
