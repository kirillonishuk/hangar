import Foundation

/// The folder name claude keeps a cwd's conversations under (`<config>/projects/<name>`): every UTF-16 unit that is not
/// an ASCII letter or digit becomes `-`, as its `replace(/[^a-zA-Z0-9]/g, "-")`. nil when longer than claude keeps as is
/// (it shortens those with a hash Hangar doesn't reproduce): no copy there, lookups fall back to scanning.
public func claudeProjectFolder(_ path: String) -> String? {
    let name = String(path.utf16.map { u -> Character in
        let alnum = (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u)
        return alnum ? Character(Unicode.Scalar(UInt8(u))) : "-"
    })
    return name.count <= 200 ? name : nil
}

/// The first `cwd` among a transcript's first lines (JSON, so escaped paths compare right); nil when none has one.
func firstRecordedCwd(_ data: Data) -> String? {
    for line in data.prefix(1_048_576).split(separator: UInt8(ascii: "\n")).prefix(200) {
        if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let cwd = object["cwd"] as? String {
            return cwd
        }
    }
    return nil
}

public enum TranscriptSync: Equatable, Sendable {
    /// Copied (or refreshed) into the new folder's place.
    case copied
    /// Hangar's copy is already as long as the original.
    case upToDate
    /// No transcript of the id anywhere (nothing was said).
    case noSource
    /// Left alone: a transcript there that Hangar didn't make (claude's own), or a folder name claude shortens.
    case skipped
}

/// A relinked worktree's claude conversation `id` (#122), run when its tab next launches: the transcript (found as claude
/// would, `projects/*/<id>.jsonl`, the folder of `recordedIn` first) is copied to the folder claude reads from `cwd`, so
/// `--resume` continues it there. Copy only: the original stays. Lines whose top-level `cwd` is the transcript's own first
/// `cwd` or `recordedIn` get `cwd`; every other byte is kept; the `<id>/` folder next to it (subagents) is copied as is.
/// A copy Hangar made earlier (its `.<id>.hangar-copy` note) is replaced when the original grew and the copy didn't;
/// a transcript Hangar didn't make is never touched. Leftover temp files of an interrupted copy are removed first.
@discardableResult
public func syncClaudeTranscript(id: String, recordedIn old: String, cwd new: String, configDir: URL) throws -> TranscriptSync {
    let fm = FileManager.default
    let projects = configDir.appendingPathComponent("projects")
    guard let name = claudeProjectFolder(new) else { return .skipped }
    let target = projects.appendingPathComponent(name)
    let file = target.appendingPathComponent(id + ".jsonl")
    let note = target.appendingPathComponent(".\(id).hangar-copy")
    let tmpPrefix = ".\(id).jsonl.hangar-tmp-"
    for leftover in (try? fm.contentsOfDirectory(atPath: target.path)) ?? [] where leftover.hasPrefix(tmpPrefix) {
        try? fm.removeItem(at: target.appendingPathComponent(leftover))
    }
    let realOld = URL(fileURLWithPath: old).resolvingSymlinksInPath().path
    let first = [old, realOld].compactMap(claudeProjectFolder)
    let all = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
    guard let source = (first + all.sorted()).lazy.filter({ $0 != name })
            .map({ projects.appendingPathComponent($0) })
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent(id + ".jsonl").path) }) else { return .noSource }
    let sourceFile = source.appendingPathComponent(id + ".jsonl")
    func size(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue }
    if fm.fileExists(atPath: file.path) {
        // Ours: "<original size> <copy size>" when made. Replaced only while claude hasn't written to the copy.
        guard let made = try? String(contentsOf: note, encoding: .utf8).split(separator: " ").compactMap({ Int($0) }),
              made.count == 2, size(file) == made[1] else { return .skipped }
        guard let now = size(sourceFile), now > made[0] else { return .upToDate }
    }
    let data = try Data(contentsOf: sourceFile)
    let olds = Set([old, realOld] + [firstRecordedCwd(data)].compactMap { $0 })
    var out = Data()
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    for (n, line) in lines.enumerated() {
        out.append(rewriteCwd(Data(line), olds: olds, new: new))
        if n < lines.count - 1 { out.append(UInt8(ascii: "\n")) }
    }
    try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let perms = (try? fm.attributesOfItem(atPath: sourceFile.path)[.posixPermissions]) ?? 0o600
    let tmp = target.appendingPathComponent(tmpPrefix + UUID().uuidString)
    guard fm.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: perms]) else { throw CocoaError(.fileWriteUnknown) }
    guard rename(tmp.path, file.path) == 0 else {
        try? fm.removeItem(at: tmp)
        throw CocoaError(.fileWriteUnknown)
    }
    _ = fm.createFile(atPath: note.path, contents: Data("\(data.count) \(out.count)".utf8), attributes: [.posixPermissions: 0o600])
    let sidecar = source.appendingPathComponent(id), sidecarCopy = target.appendingPathComponent(id)
    if fm.fileExists(atPath: sidecar.path) {
        try? fm.removeItem(at: sidecarCopy)  // only ever ours: the transcript next to it was
        try? fm.copyItem(at: sidecar, to: sidecarCopy)
    }
    return .copied
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
