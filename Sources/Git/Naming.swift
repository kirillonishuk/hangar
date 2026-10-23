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
    let slug = branchSlug(branch)
    if var root {
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return (root == "/" ? "" : root) + "/" + slug
    }
    var p = projectPath
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    let url = URL(fileURLWithPath: p, isDirectory: true)  // no stat: the path may be on a server
    return url.deletingLastPathComponent().path + "/" + url.lastPathComponent + ".worktrees/" + slug
}
