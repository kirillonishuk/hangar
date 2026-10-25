import Foundation

/// `home` and anything under it shown with `~` (local paths only: a server's home is not this Mac's).
func abbreviatedHomePath(_ path: String, home: String = NSHomeDirectory()) -> String {
    var home = home
    while home.count > 1, home.hasSuffix("/") { home.removeLast() }
    if path == home || path == home + "/" { return "~" + path.dropFirst(home.count) }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// `path` cut in the middle at component boundaries so the last components stay readable
/// (`~/Documents/…/app/.claude/worktrees`); more trailing components win over a longer head.
func middleTruncatedPath(_ path: String, maxLength: Int) -> String {
    guard path.count > maxLength else { return path }
    guard maxLength > 1 else { return maxLength == 1 ? "…" : "" }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    var best: (tail: Int, text: String)?
    for headCount in [2, 1] where parts.count > headCount + 1 {
        let head = parts[..<headCount].joined(separator: "/") + "/…/"
        var tail: [String] = []
        for part in parts[headCount...].reversed() {
            let next = ([part] + tail).joined(separator: "/")
            guard head.count + next.count <= maxLength else { break }
            tail.insert(part, at: 0)
        }
        if !tail.isEmpty, tail.count > (best?.tail ?? 0) { best = (tail.count, head + tail.joined(separator: "/")) }
    }
    return best?.text ?? "…" + path.suffix(maxLength - 1)
}

/// Where «Choose…» opens: `value` if it exists, else its nearest existing parent; blank or relative → `fallback` the same way.
func panelStartDirectory(_ value: String, fallback: String, home: String = NSHomeDirectory(),
                         exists: (String) -> Bool) -> String {
    var dir = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if dir == "~" || dir.hasPrefix("~/") { dir = home + dir.dropFirst() }
    if !dir.hasPrefix("/") { dir = fallback }
    while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
    while dir != "/", !dir.isEmpty, !exists(dir) { dir = (dir as NSString).deletingLastPathComponent }
    return dir.isEmpty ? "/" : dir
}
