import Foundation

private let translit: [Character: String] = [
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
    "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
    "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y",
    "ь": "", "э": "e", "ю": "yu", "я": "ya",
]

/// Task name -> git branch name: transliterated, lowercase, only `[a-z0-9._]` and single `-`.
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
        if c == "-", out.last == "-" { continue }
        out.append(c)
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return trimmed.isEmpty ? "task" : trimmed
}

/// Default: `<dirname>/<basename>.worktrees/<slug>`; with `root`: `<root>/<slug>`.
public func worktreePath(projectPath: String, root: String?, branch: String) -> String {
    let slug = branchSlug(branch)
    if let root { return root + "/" + slug }
    var p = projectPath
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    let url = URL(fileURLWithPath: p)
    return url.deletingLastPathComponent().path + "/" + url.lastPathComponent + ".worktrees/" + slug
}
