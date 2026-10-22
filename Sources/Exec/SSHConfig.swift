import Foundation

/// Total bytes read across the config and its includes; past it the rest is skipped (a stray `Include /dev/*` or a huge file).
let sshConfigByteCap = 1 << 20

/// Concrete host names from `Host` lines of the ssh config at `path` and the files it `Include`s (as OpenSSH: in place,
/// relative paths against `sshDir`, globs, several per line, depth ≤ 16), in order, without duplicates. Patterns (`*`, `?`),
/// negations (`!`), names that `validSSHHost` rejects and `Include` inside `Match` (conditional) are skipped.
/// Files are only read; each one once (cycles), at most `sshConfigByteCap` bytes in total.
/// shortcut: `%` tokens and `${VAR}` in `Include` are not expanded; add them when users ask.
public func sshConfigHosts(path: String, sshDir: String? = nil,
                           read: (String) -> Data? = readSSHConfigFile) -> [String] {
    let base = sshDir ?? (path as NSString).deletingLastPathComponent  // ~/.ssh for the real config
    var hosts: [String] = [], seen = Set<String>(), visited = Set<String>(), budget = sshConfigByteCap

    func load(_ file: String, depth: Int) {
        guard budget > 0, visited.insert(URL(fileURLWithPath: file).resolvingSymlinksInPath().path).inserted,
              let data = read(file) else { return }
        guard data.count <= budget else { budget = 0; return }
        budget -= data.count
        var inMatch = false  // a Match block lasts until the next Host or Match; this file's state only, like OpenSSH
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let end = line.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else { continue }
            var rest = line[end...].drop(while: \.isWhitespace)
            if rest.first == "=" { rest = rest.dropFirst() }
            switch line[..<end].lowercased() {
            case "match": inMatch = true
            case "host":
                inMatch = false
                for word in rest.split(whereSeparator: \.isWhitespace).map(String.init) {
                    if word.hasPrefix("#") { break }  // trailing comment
                    if !word.contains(where: { "*?!#\"".contains($0) }), validSSHHost(word) != nil, seen.insert(word).inserted {
                        hosts.append(word)
                    }
                }
            case "include" where !inMatch && depth < 16:
                for word in configWords(rest) {
                    let pattern = word.hasPrefix("~") ? (word as NSString).expandingTildeInPath
                        : word.hasPrefix("/") ? word : base + "/" + word
                    for match in globPaths(pattern) { load(match, depth: depth + 1) }
                }
            default: break
            }
        }
    }
    load(path, depth: 0)
    return hosts
}

/// The file's first `sshConfigByteCap + 1` bytes (enough to see it is over the cap); nil if it can't be opened.
public func readSSHConfigFile(_ path: String) -> Data? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    do { return try handle.read(upToCount: sshConfigByteCap + 1) ?? Data() } catch { return nil }  // nil read = empty file
}

/// Whitespace-separated words with `"…"` quoting, up to a `#` comment (OpenSSH's argv_split, minus escapes).
private func configWords(_ s: Substring) -> [String] {
    var words: [String] = [], word = "", quoted = false, inWord = false
    for c in s {
        if c == "\"" { quoted.toggle(); inWord = true }
        else if c.isWhitespace && !quoted { if inWord { words.append(word) }; word = ""; inWord = false }
        else if c == "#" && !quoted && !inWord { break }
        else { word.append(c); inWord = true }
    }
    if inWord && !quoted { words.append(word) }
    return words
}

/// Sorted paths matching a glob(3) pattern; none if nothing matches.
private func globPaths(_ pattern: String) -> [String] {
    var g = glob_t()
    defer { globfree(&g) }
    guard glob(pattern, 0, nil, &g) == 0 else { return [] }
    return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
}
