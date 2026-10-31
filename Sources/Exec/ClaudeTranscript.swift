import Foundation

/// The folder name claude keeps a cwd's conversations under (`<config>/projects/<name>`): every UTF-16 unit that is not
/// an ASCII letter or digit becomes `-`, as its `replace(/[^a-zA-Z0-9]/g, "-")`.
/// shortcut: claude shortens very long names (over 200) with a hash; those are not matched, the scan of all folders still finds the file.
public func claudeProjectFolder(_ path: String) -> String {
    String(path.utf16.map { u -> Character in
        let alnum = (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u)
        return alnum ? Character(Unicode.Scalar(UInt8(u))) : "-"
    })
}

/// A moved worktree (#122): copies conversation `id` recorded in `old` to claude's folder for `new`, so `--resume` finds it
/// from there. Copy only: the original stays. Lines whose top-level `cwd` is `old` get `new`; every other byte is kept. The
/// `<id>/` folder next to it (subagents, tool results) is copied as is. Nothing happens when the copy exists or the source
/// doesn't. Returns whether it copied.
@discardableResult
public func copyClaudeTranscript(id: String, from old: String, to new: String, configDir: URL) throws -> Bool {
    let fm = FileManager.default
    let projects = configDir.appendingPathComponent("projects")
    let target = projects.appendingPathComponent(claudeProjectFolder(new))
    let file = target.appendingPathComponent(id + ".jsonl")
    let realOld = URL(fileURLWithPath: old).resolvingSymlinksInPath().path
    guard !fm.fileExists(atPath: file.path),
          let source = [old, realOld].lazy.map({ projects.appendingPathComponent(claudeProjectFolder($0)) })
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent(id + ".jsonl").path) }) else { return false }
    let data = try Data(contentsOf: source.appendingPathComponent(id + ".jsonl"))
    let olds: Set<String> = [old, realOld]
    var out = Data()
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    for (n, line) in lines.enumerated() {
        out.append(rewriteCwd(Data(line), olds: olds, new: new))
        if n < lines.count - 1 { out.append(UInt8(ascii: "\n")) }
    }
    try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let perms = (try? fm.attributesOfItem(atPath: source.appendingPathComponent(id + ".jsonl").path)[.posixPermissions]) ?? 0o600
    let tmp = target.appendingPathComponent(".\(id).jsonl.hangar-\(UUID().uuidString)")
    guard fm.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: perms]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    do {
        try fm.moveItem(at: tmp, to: file)  // fails if the file appeared meanwhile: the existing one stays
    } catch {
        try? fm.removeItem(at: tmp)
        throw error
    }
    let sidecar = source.appendingPathComponent(id), sidecarCopy = target.appendingPathComponent(id)
    if fm.fileExists(atPath: sidecar.path), !fm.fileExists(atPath: sidecarCopy.path) {
        try? fm.copyItem(at: sidecar, to: sidecarCopy)
    }
    return true
}

/// The line with its top-level `cwd` replaced when it is one of `olds`: the `"cwd":"…"` text itself when it is there as
/// claude writes it, else the line re-encoded. Other lines (and lines that aren't JSON objects) come back unchanged.
func rewriteCwd(_ line: Data, olds: Set<String>, new: String) -> Data {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let cwd = object["cwd"] as? String, olds.contains(cwd) else { return line }
    func literal(_ s: String) -> Data? {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]) else { return nil }
        return d.dropFirst().dropLast()  // `["…"]` → `"…"`
    }
    if let from = literal(cwd), let to = literal(new) {
        let key = Data(#""cwd":"#.utf8)
        if let r = line.range(of: key + from) {
            var out = line
            out.replaceSubrange(r, with: key + to)
            // The first match must be the top-level field: checked by reading the result back.
            if let check = try? JSONSerialization.jsonObject(with: out) as? [String: Any], check["cwd"] as? String == new { return out }
        }
    }
    var copy = object
    copy["cwd"] = new
    return (try? JSONSerialization.data(withJSONObject: copy, options: [.withoutEscapingSlashes])) ?? line
}
