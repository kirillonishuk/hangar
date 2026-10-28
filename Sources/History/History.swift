import AgentStatus
import Exec
import Foundation

/// Past agent conversations of a folder («Сессии»): read-only from `~/.claude/projects` and `~/.codex/sessions`.
public enum HistoryAgent: String, Sendable { case claude, codex }

public struct Conversation: Equatable, Sendable, Identifiable {
    /// For `claude --resume <id>` / `codex resume <id>`; always passed `validSessionId`.
    public var id: String
    public var agent: HistoryAgent
    public var cwd: String
    public var started: Date?
    public var lastActivity: Date
    /// Exact when the whole file was read; else extrapolated from the head and tail (`messageCountIsEstimate`).
    public var messageCount: Int
    public var messageCountIsEstimate: Bool
    public var gitBranch: String?
    /// First user prompt, one line, at most 80 characters.
    public var title: String?
    /// Some live Hangar leaf has this session id.
    public var isOpen: Bool

    public init(id: String, agent: HistoryAgent, cwd: String, started: Date?, lastActivity: Date, messageCount: Int,
                messageCountIsEstimate: Bool, gitBranch: String?, title: String?, isOpen: Bool) {
        self.id = id; self.agent = agent; self.cwd = cwd; self.started = started; self.lastActivity = lastActivity
        self.messageCount = messageCount; self.messageCountIsEstimate = messageCountIsEstimate
        self.gitBranch = gitBranch; self.title = title; self.isOpen = isOpen
    }
}

public enum HistoryError: Error, Equatable { case remote(String) }

/// Claude Code's folder name for a cwd: every non-alphanumeric character becomes `-`.
public func claudeProjectDirName(_ path: String) -> String {
    String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
}

/// Claude Code cuts longer names to this many characters and appends `-<hash>`.
private let claudeNameLimit = 200

/// `inside`: also the folders of paths inside it (the name continues with `-`; the recorded cwd confirms).
func claudeDirMatches(_ name: String, encoded: String, inside: Bool = false) -> Bool {
    name == encoded || (inside && name.hasPrefix(encoded + "-"))
        || (encoded.count > claudeNameLimit && name.hasPrefix(encoded.prefix(claudeNameLimit) + "-"))
}

/// Control characters (C0, C1: ESC, NUL…) and bidi overrides/isolates/marks: a title is untrusted file content.
private func isUnsafe(_ u: Unicode.Scalar) -> Bool {
    u.properties.generalCategory == .control || (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value)
        || u.value == 0x200E || u.value == 0x200F || u.value == 0x061C
}

/// First non-empty line, unsafe characters dropped, whitespace collapsed, cut to 80 characters and 160 scalars
/// (combining marks pile up inside one character) with «…».
public func conversationTitle(_ text: String) -> String? {
    guard let line = text.split(whereSeparator: \.isNewline).lazy
        .map({ String(String.UnicodeScalarView($0.unicodeScalars.filter { $0.properties.isWhitespace || !isUnsafe($0) })) })
        .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }).first(where: { !$0.isEmpty })
    else { return nil }
    var out = "", scalars = 0, chars = 0
    for c in line {
        let n = c.unicodeScalars.count
        guard chars < 80, scalars + n <= 160 else { break }
        out.append(c); chars += 1; scalars += n
    }
    guard out.count < line.count else { return line }
    // Room for «…» within both caps.
    while out.count > 79 || out.unicodeScalars.count > 159 { out.removeLast() }
    return out + "…"
}

/// Head and tail of one file; `whole` when nothing in between was skipped.
struct Sample {
    var head: Data
    var tail: Data
    var whole: Bool
    var size: Int

    /// Complete lines only: a cut line at either edge is dropped.
    var lines: [[String: Any]] {
        func split(_ d: Data) -> [Data] { d.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) } }
        var raw: [Data]
        if whole {
            raw = split(head)
        } else {
            var h = split(head), t = split(tail)
            if head.last != 0x0A, !h.isEmpty { h.removeLast() }
            if !t.isEmpty { t.removeFirst() }
            raw = h + t
        }
        return raw.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

nonisolated(unsafe) private let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
nonisolated(unsafe) private let plain = ISO8601DateFormatter()

private func date(_ v: Any?) -> Date? {
    guard let s = v as? String else { return nil }
    return fractional.date(from: s) ?? plain.date(from: s)
}

/// Messages seen in the sample, or extrapolated over the whole file by byte density.
private func messageCount(_ seen: Int, _ s: Sample) -> (Int, Bool) {
    if s.whole { return (seen, false) }
    let sampled = max(s.head.count + s.tail.count, 1)
    return (Int((Double(seen) * Double(s.size) / Double(sampled)).rounded()), true)
}

private func promptText(_ message: Any?) -> String? {
    let content = (message as? [String: Any])?["content"]
    if let s = content as? String { return s }
    guard let items = content as? [[String: Any]], !items.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
    return items.first { $0["type"] as? String == "text" }?["text"] as? String
}

/// Wrapped commands and context blocks (`<command-name>`, `<environment_context>`) are not the user's words.
private func titleCandidate(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return nil }
    return conversationTitle(text)
}

/// `path` is `folder` or inside it.
private func within(_ path: String, _ folders: Set<String>) -> Bool {
    folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
}

/// One parsed file, independent of the folder asked about (the cache is per file): the conversation and every cwd it recorded.
struct Record: Sendable {
    var conversation: Conversation
    var cwds: [String]
    /// Claude: the project folder the file lives in (named after the cwd it was started in); nil for Codex.
    var dirName: String?
}

/// The record as a conversation of `folders`, or nil. Codex: its cwd is one of them. Claude: the folder name is lossy
/// ("/a-b" and "/a/b" share it), so a recorded cwd decides — any of them, since the first line may carry another folder
/// (a resumed or moved conversation) — and it may be inside them. Its cwd is the one the file's folder is named after,
/// where `--resume` finds it.
func placed(_ r: Record, in folders: Set<String>) -> Conversation? {
    var c = r.conversation
    guard let dirName = r.dirName else { return folders.contains(c.cwd) ? c : nil }
    let named: (String) -> Bool = { claudeDirMatches(dirName, encoded: claudeProjectDirName($0)) }
    if r.cwds.isEmpty {
        guard let f = folders.sorted().first(where: named) else { return nil }
        c.cwd = f
        return c
    }
    let inside = r.cwds.filter { within($0, folders) }
    guard let first = inside.first else { return nil }
    c.cwd = r.cwds.first(where: named) ?? first
    return c
}

/// `<id>.jsonl` in the Claude project folder `dirName`; nil — not a conversation (sidechain file, no messages). The title
/// is Claude's own: `/rename` (`custom-title`), else its generated `ai-title`, else the first prompt; both records are
/// appended again on later turns, so the latest in the sample wins.
// shortcut: a rename seen only in the unread middle of a huge file is missed until Claude appends it again.
func parseClaude(_ s: Sample, fileName: String, dirName: String, mtime: Date?) -> Record? {
    guard fileName.hasSuffix(".jsonl"), !fileName.hasPrefix("agent-"),
          let id = validSessionId(String(fileName.dropLast(6))) else { return nil }
    var count = 0, started: Date?, last: Date?, cwds: [String] = [], branch: String?
    var prompt: String?, customTitle: String?, aiTitle: String?
    for o in s.lines {
        if let d = date(o["timestamp"]) { started = started ?? d; last = d }
        if let c = o["cwd"] as? String, !cwds.contains(c) { cwds.append(c) }
        if let b = o["gitBranch"] as? String, !b.isEmpty { branch = b }
        let type = o["type"] as? String
        if type == "custom-title", let t = (o["customTitle"] as? String).flatMap(conversationTitle) { customTitle = t }
        if type == "ai-title", let t = (o["aiTitle"] as? String).flatMap(conversationTitle) { aiTitle = t }
        guard type == "user" || type == "assistant", o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true else { continue }
        count += 1
        if prompt == nil, type == "user" { prompt = titleCandidate(promptText(o["message"])) }
    }
    guard count > 0 else { return nil }
    let (n, estimate) = messageCount(count, s)
    let c = Conversation(id: id, agent: .claude, cwd: cwds.first ?? "", started: started, lastActivity: last ?? mtime ?? started ?? .distantPast,
                         messageCount: n, messageCountIsEstimate: estimate, gitBranch: branch,
                         title: customTitle ?? aiTitle ?? prompt, isOpen: false)
    return Record(conversation: c, cwds: cwds, dirName: dirName)
}

/// `rollout-<time>-<id>.jsonl`: the id and cwd come from its `session_meta` line.
func parseCodex(_ s: Sample, fileName: String, mtime: Date?) -> Record? {
    var count = 0, started: Date?, last: Date?, cwd: String?, branch: String?, title: String?, id: String?
    for o in s.lines {
        if let d = date(o["timestamp"]) { started = started ?? d; last = d }
        guard let p = o["payload"] as? [String: Any] else { continue }
        switch (o["type"] as? String, p["type"] as? String) {
        case ("session_meta", _):
            id = id ?? validSessionId(p["id"] as? String)
            cwd = cwd ?? p["cwd"] as? String
            branch = ((p["git"] as? [String: Any])?["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case ("event_msg", "user_message"):
            count += 1
            if title == nil { title = titleCandidate(p["message"] as? String) }
        case ("event_msg", "agent_message"):
            count += 1
        default: break
        }
    }
    let stem = fileName.hasSuffix(".jsonl") ? String(fileName.dropLast(6)) : fileName
    guard let id = id ?? validSessionId(String(stem.suffix(36))), count > 0, let cwd else { return nil }
    let (n, estimate) = messageCount(count, s)
    let c = Conversation(id: id, agent: .codex, cwd: cwd, started: started, lastActivity: last ?? mtime ?? started ?? .distantPast,
                         messageCount: n, messageCountIsEstimate: estimate, gitBranch: branch, title: title, isOpen: false)
    return Record(conversation: c, cwds: [cwd], dirName: nil)
}

/// Head and tail of a local file (the whole file when it is small); nothing on a read error.
func sampleFile(_ url: URL, size: Int, head: Int, tail: Int) -> Sample {
    func read(_ offset: Int, _ count: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(offset))) != nil, let d = try? h.read(upToCount: count) else { return Data() }
        return d
    }
    if size <= head + tail { return Sample(head: read(0, size), tail: Data(), whole: true, size: size) }
    return Sample(head: read(0, head), tail: read(size - tail, tail), whole: false, size: size)
}

/// The cwd in a rollout's first bytes (`session_meta` puts it before the long instructions); nil if not there.
func codexPrefixCwd(_ prefix: Data) -> String? {
    guard let key = prefix.range(of: Data(#""cwd":""#.utf8)) else { return nil }
    var i = key.upperBound, escaped = false
    while i < prefix.endIndex {
        let b = prefix[i]
        if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { break }
        i += 1
    }
    guard i < prefix.endIndex else { return nil }
    let literal = Data("[".utf8) + prefix[(key.upperBound - 1)...i] + Data("]".utf8)
    return (try? JSONSerialization.jsonObject(with: literal) as? [String])?.first
}

/// The bytes a rollout's first line has for `cwd` (Codex writes compact JSON, slashes unescaped).
func codexNeedle(_ cwd: String) -> String {
    let quoted = (try? JSONSerialization.data(withJSONObject: [cwd], options: [.withoutEscapingSlashes]))
        .map { String(decoding: $0.dropFirst().dropLast(), as: UTF8.self) } ?? "\"\(cwd)\""
    return "\"cwd\":" + quoted
}

/// The cwd sits before the long instructions in `session_meta`, so this prefix of a rollout is enough to match it.
let codexPrefixBytes = 8192

private func normalized(_ path: String) -> String {
    var p = path
    while p.count > 1, p.hasSuffix("/") { p.removeLast() }
    return p
}

/// Lists conversations on every call (the view rescans when it opens; no watchers) and re-reads only files whose
/// mtime/size changed since the last call. The cache is per file, so overlapping folders (a project and its worktrees,
/// nested projects) read each file once.
// shortcut: entries of deleted files stay until relaunch (a few hundred bytes each).
public actor ConversationHistory {
    /// `record`: the parsed file (nil — not a conversation, or a rollout not sampled); `codexCwd`: a rollout's cwd from its prefix.
    private struct Entry { var stamp: String; var record: Record?; var codexCwd: String? = nil; var sampled = true }
    private var cache: [String: Entry] = [:]
    public static let defaultHeadBytes = 131_072, defaultTailBytes = 65_536
    /// Files fetched per remote call: the reply (≤ head + tail each) stays well below the host runner's output cap.
    public static let remoteBatch = 100
    private let headBytes: Int, tailBytes: Int
    /// Files sampled and bytes read so far (tests check the cache and the read budget).
    public private(set) var filesParsed = 0
    public private(set) var bytesRead = 0

    public init(headBytes: Int = defaultHeadBytes, tailBytes: Int = defaultTailBytes) {
        self.headBytes = headBytes
        self.tailBytes = tailBytes
    }

    // MARK: Local

    /// `claudeDir` / `codexDir`: the agents' config folders (`~/.claude`, `~/.codex` or their env overrides).
    public func local(folder: String, claudeDir: URL, codexDir: URL, open: Set<String>) async -> [Conversation] {
        let folder = normalized(folder)
        let folders: Set<String> = [folder, URL(fileURLWithPath: folder).resolvingSymlinksInPath().path]
        let fm = FileManager.default
        var out: [Conversation] = []

        let projects = claudeDir.appendingPathComponent("projects")
        let names = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        // Also folders inside the project (subfolders, Claude's own worktrees): their names start with `<name>-`.
        var files: [(url: URL, file: String, dir: String)] = []
        var stale: [ClaudeJob] = []
        for dir in names where folders.contains(where: { claudeDirMatches(dir, encoded: claudeProjectDirName($0), inside: true) }) {
            let d = projects.appendingPathComponent(dir)
            for file in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where file.hasSuffix(".jsonl") {
                let url = d.appendingPathComponent(file)
                guard let (stamp, mtime, size) = fileStamp(url) else { continue }
                files.append((url, file, dir))
                if cache[url.path]?.stamp != stamp { stale.append(ClaudeJob(url: url, file: file, dir: dir, stamp: stamp, mtime: mtime, size: size)) }
            }
        }
        // Parsing the samples is the cost (JSON of ~190 KB a file): changed files are parsed on all cores.
        for (job, record, bytes) in await parseAll(stale) {
            filesParsed += 1
            bytesRead += bytes
            cache[job.url.path] = Entry(stamp: job.stamp, record: record)
        }
        for f in files {
            if let c = cache[f.url.path]?.record.flatMap({ placed($0, in: folders) }) { out.append(c) }
        }

        let sessions = codexDir.appendingPathComponent("sessions")
        let walker = fm.enumerator(at: sessions, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            let file = url.lastPathComponent
            guard file.hasPrefix("rollout-"), file.hasSuffix(".jsonl") else { continue }
            guard let (stamp, mtime, size) = fileStamp(url) else { continue }
            var e = cache[url.path].flatMap { $0.stamp == stamp ? $0 : nil }
                ?? Entry(stamp: stamp, record: nil, codexCwd: codexPrefixCwd(read(url, from: 0, count: codexPrefixBytes)), sampled: false)
            // Only rollouts of this folder are sampled; the prefix cwd stays cached for the others.
            if !e.sampled, let cwd = e.codexCwd, folders.contains(cwd) {
                filesParsed += 1
                e.sampled = true
                e.record = parseCodex(sample(url, size: size), fileName: file, mtime: mtime)
            }
            cache[url.path] = e
            if let c = e.record.flatMap({ placed($0, in: folders) }) { out.append(c) }
        }
        return sorted(out, open: open)
    }

    struct ClaudeJob: Sendable {
        var url: URL, file: String, dir: String, stamp: String, mtime: Date?, size: Int
    }

    /// Samples and parses the files off the actor, a few at a time per core; results in no particular order.
    private func parseAll(_ jobs: [ClaudeJob]) async -> [(ClaudeJob, Record?, Int)] {
        guard !jobs.isEmpty else { return [] }
        let head = headBytes, tail = tailBytes
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        return await withTaskGroup(of: (ClaudeJob, Record?, Int).self) { group in
            var next = 0, out: [(ClaudeJob, Record?, Int)] = []
            func add() {
                let job = jobs[next]
                next += 1
                group.addTask {
                    let s = sampleFile(job.url, size: job.size, head: head, tail: tail)
                    return (job, parseClaude(s, fileName: job.file, dirName: job.dir, mtime: job.mtime), s.head.count + s.tail.count)
                }
            }
            while next < min(width, jobs.count) { add() }
            while let r = await group.next() {
                out.append(r)
                if next < jobs.count { add() }
            }
            return out
        }
    }

    private func fileStamp(_ url: URL) -> (String, Date?, Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let m = a[.modificationDate] as? Date, size = (a[.size] as? NSNumber)?.intValue ?? 0
        return ("\(m?.timeIntervalSince1970 ?? 0)-\(size)", m, size)
    }

    private func sample(_ url: URL, size: Int) -> Sample {
        if size <= headBytes + tailBytes { return Sample(head: read(url, from: 0, count: size), tail: Data(), whole: true, size: size) }
        return Sample(head: read(url, from: 0, count: headBytes), tail: read(url, from: size - tailBytes, count: tailBytes),
                      whole: false, size: size)
    }

    private func read(_ url: URL, from offset: Int, count: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(offset))) != nil, let d = try? h.read(upToCount: count) else { return Data() }
        bytesRead += d.count
        return d
    }

    private func sorted(_ list: [Conversation], open: Set<String>) -> [Conversation] {
        list.map { c in var c = c; c.isOpen = open.contains(c.id); return c }
            .sorted { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }
    }

    // MARK: Remote

    /// The same listing on an ssh host through its runner: one call lists the files (with sizes), a second fetches
    /// head and tail of those that changed. `host` keys the cache.
    // shortcut: remote files are cached by size only (no portable stat for mtime); a same-size rewrite shows stale data until it grows.
    public func remote(folder: String, host: String, runner: Runner, open: Set<String>) async throws -> [Conversation] {
        let folder = normalized(folder)
        let folders: Set<String> = [folder]
        let encoded = claudeProjectDirName(folder)
        let long = encoded.count > claudeNameLimit
        let listing = try await run(runner, remoteListScript,
                                    [long ? String(encoded.prefix(claudeNameLimit)) : encoded, long ? "1" : "0", codexNeedle(folder)])
        let scope = "ssh:" + host + "\0"
        var files: [(agent: HistoryAgent, path: String, stamp: String)] = []
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let agent: HistoryAgent = f[0] == "C" ? .claude : f[0] == "X" ? .codex : nil,
                  f[2].hasPrefix("/") else { continue }
            files.append((agent, f[2], f[1].trimmingCharacters(in: .whitespaces)))
        }
        let stale = files.filter { cache[scope + $0.path]?.stamp != $0.stamp }
        var start = 0
        while start < stale.count {
            let batch = Array(stale[start..<min(start + Self.remoteBatch, stale.count)])
            start += batch.count
            let out = try await run(runner, remoteFetchScript, [String(headBytes), String(tailBytes)] + batch.map(\.path))
            var samples: [String: Sample] = [:]
            for chunk in out.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
                guard let nl = chunk.firstIndex(of: "\n") else { continue }
                let header = chunk[..<nl].split(separator: "\t", maxSplits: 1).map(String.init)
                guard header.count == 2, let size = Int(header[0]) else { continue }
                let body = chunk[chunk.index(after: nl)...]
                let parts = body.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                samples[header[1]] = parts.count == 2
                    ? Sample(head: Data(parts[0].utf8), tail: Data(parts[1].utf8), whole: false, size: size)
                    : Sample(head: Data(body.utf8), tail: Data(), whole: true, size: size)
            }
            for f in batch {
                guard let s = samples[f.path] else { continue }
                filesParsed += 1
                let name = (f.path as NSString).lastPathComponent
                let dir = ((f.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let r = f.agent == .claude ? parseClaude(s, fileName: name, dirName: dir, mtime: nil)
                                           : parseCodex(s, fileName: name, mtime: nil)
                cache[scope + f.path] = Entry(stamp: f.stamp, record: r)
            }
        }
        let list = files.compactMap { cache[scope + $0.path]?.record.flatMap { placed($0, in: folders) } }
        return sorted(list, open: open)
    }

    private func run(_ runner: Runner, _ script: String, _ args: [String]) async throws -> String {
        let r: RunResult
        do { r = try await runner.run(["/bin/sh", "-c", script, "sh"] + args, "") } catch { throw HistoryError.remote("\(error)") }
        guard r.status == 0 else { throw HistoryError.remote(r.stderr) }
        return r.stdout
    }
}

/// `$1` Claude folder name (or its 200-character prefix when `$2` = 1; folders inside it too), `$3` the rollout cwd needle.
/// Prints `C|X <tab> size <tab> path` per conversation file; reads nothing but listings and rollout prefixes.
let remoteListScript = #"""
c=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
x=${CODEX_HOME:-$HOME/.codex}/sessions
needle=$3
if [ "$2" = 1 ]; then set -- "$c/$1"-*; else set -- "$c/$1" "$c/$1"-*; fi
for d in "$@"; do
  [ -d "$d" ] || continue
  for f in "$d"/*.jsonl; do
    [ -f "$f" ] && printf 'C\t%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"
  done
done
if [ -d "$x" ]; then
  find "$x/" -type f -name 'rollout-*.jsonl' | while IFS= read -r f; do
    head -c \#(codexPrefixBytes) "$f" | grep -qF -e "$needle" && printf 'X\t%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"
  done
fi
exit 0
"""#

/// `$1` head bytes, `$2` tail bytes, then paths. Per file: RS, `size <tab> path`, newline, then the whole file or
/// head US tail. JSON lines never hold raw RS/US bytes.
let remoteFetchScript = #"""
h=$1; t=$2; shift 2
for f in "$@"; do
  [ -f "$f" ] || continue
  s=$(wc -c < "$f" | tr -d ' ')
  printf '\036%s\t%s\n' "$s" "$f"
  if [ "$s" -le $((h + t)) ]; then cat "$f"; else head -c "$h" "$f"; printf '\037'; tail -c "$t" "$f"; fi
done
exit 0
"""#
