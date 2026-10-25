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

func claudeDirMatches(_ name: String, encoded: String) -> Bool {
    name == encoded || (encoded.count > claudeNameLimit && name.hasPrefix(encoded.prefix(claudeNameLimit) + "-"))
}

/// First non-empty line, whitespace collapsed, cut to 80 characters with «…».
public func conversationTitle(_ text: String) -> String? {
    guard let line = text.split(whereSeparator: \.isNewline).lazy
        .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }).first(where: { !$0.isEmpty })
    else { return nil }
    return line.count > 80 ? String(line.prefix(79)) + "…" : line
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

/// `<id>.jsonl` in a Claude project folder; nil — not a conversation of `folders` (sidechain file, other cwd, no messages).
func parseClaude(_ s: Sample, fileName: String, folders: Set<String>, mtime: Date?) -> Conversation? {
    guard fileName.hasSuffix(".jsonl"), !fileName.hasPrefix("agent-"),
          let id = validSessionId(String(fileName.dropLast(6))) else { return nil }
    var count = 0, started: Date?, last: Date?, cwd: String?, branch: String?, title: String?
    for o in s.lines {
        if let d = date(o["timestamp"]) { started = started ?? d; last = d }
        if cwd == nil, let c = o["cwd"] as? String { cwd = c }
        if let b = o["gitBranch"] as? String, !b.isEmpty { branch = b }
        let type = o["type"] as? String
        guard type == "user" || type == "assistant", o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true else { continue }
        count += 1
        if title == nil, type == "user" { title = titleCandidate(promptText(o["message"])) }
    }
    // The folder name is lossy ("/a-b" and "/a/b" share it): the recorded cwd decides.
    guard count > 0, cwd.map(folders.contains) ?? true, let any = folders.sorted().first else { return nil }
    let (n, estimate) = messageCount(count, s)
    return Conversation(id: id, agent: .claude, cwd: cwd ?? any, started: started, lastActivity: last ?? mtime ?? started ?? .distantPast,
                        messageCount: n, messageCountIsEstimate: estimate, gitBranch: branch, title: title, isOpen: false)
}

/// `rollout-<time>-<id>.jsonl`: the id and cwd come from its `session_meta` line.
func parseCodex(_ s: Sample, fileName: String, folders: Set<String>, mtime: Date?) -> Conversation? {
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
    guard let id = id ?? validSessionId(String(stem.suffix(36))), count > 0, let cwd, folders.contains(cwd) else { return nil }
    let (n, estimate) = messageCount(count, s)
    return Conversation(id: id, agent: .codex, cwd: cwd, started: started, lastActivity: last ?? mtime ?? started ?? .distantPast,
                        messageCount: n, messageCountIsEstimate: estimate, gitBranch: branch, title: title, isOpen: false)
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
/// mtime/size changed since the last call.
public actor ConversationHistory {
    private struct Entry { var stamp: String; var conversation: Conversation? }
    private var cache: [String: Entry] = [:]
    private let headBytes: Int, tailBytes: Int
    /// Files sampled and bytes read so far (tests check the cache and the read budget).
    public private(set) var filesParsed = 0
    public private(set) var bytesRead = 0

    public init(headBytes: Int = 131_072, tailBytes: Int = 65_536) {
        self.headBytes = headBytes
        self.tailBytes = tailBytes
    }

    // MARK: Local

    /// `claudeDir` / `codexDir`: the agents' config folders (`~/.claude`, `~/.codex` or their env overrides).
    public func local(folder: String, claudeDir: URL, codexDir: URL, open: Set<String>) -> [Conversation] {
        let folder = normalized(folder)
        let folders: Set<String> = [folder, URL(fileURLWithPath: folder).resolvingSymlinksInPath().path]
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [Conversation] = []

        let projects = claudeDir.appendingPathComponent("projects")
        let names = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        for dir in names where folders.contains(where: { claudeDirMatches(dir, encoded: claudeProjectDirName($0)) }) {
            let d = projects.appendingPathComponent(dir)
            for file in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where file.hasSuffix(".jsonl") {
                let url = d.appendingPathComponent(file)
                if let c = cached("local", folder, url, &seen, { s, m in parseClaude(s, fileName: file, folders: folders, mtime: m) }) {
                    out.append(c)
                }
            }
        }

        let needles = folders.map { Data(codexNeedle($0).utf8) }
        let sessions = codexDir.appendingPathComponent("sessions")
        let walker = fm.enumerator(at: sessions, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            let file = url.lastPathComponent
            guard file.hasPrefix("rollout-"), file.hasSuffix(".jsonl") else { continue }
            let c = cached("local", folder, url, &seen) { s, m in
                // The sample was taken only because the prefix check below passed.
                parseCodex(s, fileName: file, folders: folders, mtime: m)
            } precheck: {
                let prefix = read(url, from: 0, count: codexPrefixBytes)
                return needles.contains { prefix.range(of: $0) != nil }
            }
            if let c { out.append(c) }
        }
        prune("local", folder, keeping: seen)
        return sorted(out, open: open)
    }

    private func fileStamp(_ url: URL) -> (String, Date?, Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let m = a[.modificationDate] as? Date, size = (a[.size] as? NSNumber)?.intValue ?? 0
        return ("\(m?.timeIntervalSince1970 ?? 0)-\(size)", m, size)
    }

    private func cached(_ scope: String, _ folder: String, _ url: URL, _ seen: inout Set<String>,
                        _ parse: (Sample, Date?) -> Conversation?, precheck: () -> Bool = { true }) -> Conversation? {
        guard let (stamp, mtime, size) = fileStamp(url) else { return nil }
        let key = scope + "\0" + folder + "\0" + url.path
        seen.insert(key)
        if let e = cache[key], e.stamp == stamp { return e.conversation }
        var c: Conversation?
        if precheck() {
            filesParsed += 1
            c = parse(sample(url, size: size), mtime)
        }
        cache[key] = Entry(stamp: stamp, conversation: c)
        return c
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

    private func prune(_ scope: String, _ folder: String, keeping seen: Set<String>) {
        let prefix = scope + "\0" + folder + "\0"
        cache = cache.filter { !$0.key.hasPrefix(prefix) || seen.contains($0.key) }
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
        let scope = "ssh:" + host
        var seen = Set<String>()
        var files: [(agent: HistoryAgent, path: String, stamp: String)] = []
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let agent: HistoryAgent = f[0] == "C" ? .claude : f[0] == "X" ? .codex : nil,
                  f[2].hasPrefix("/") else { continue }
            files.append((agent, f[2], f[1].trimmingCharacters(in: .whitespaces)))
            seen.insert(scope + "\0" + folder + "\0" + f[2])
        }
        let stale = files.filter { cache[scope + "\0" + folder + "\0" + $0.path]?.stamp != $0.stamp }
        // Batches keep one reply far below the runner's output cap.
        var start = 0
        while start < stale.count {
            let batch = Array(stale[start..<min(start + 100, stale.count)])
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
                let c = f.agent == .claude ? parseClaude(s, fileName: name, folders: folders, mtime: nil)
                                           : parseCodex(s, fileName: name, folders: folders, mtime: nil)
                cache[scope + "\0" + folder + "\0" + f.path] = Entry(stamp: f.stamp, conversation: c)
            }
        }
        prune(scope, folder, keeping: seen)
        let list = files.compactMap { cache[scope + "\0" + folder + "\0" + $0.path]?.conversation }
        return sorted(list, open: open)
    }

    private func run(_ runner: Runner, _ script: String, _ args: [String]) async throws -> String {
        let r: RunResult
        do { r = try await runner.run(["/bin/sh", "-c", script, "sh"] + args, "") } catch { throw HistoryError.remote("\(error)") }
        guard r.status == 0 else { throw HistoryError.remote(r.stderr) }
        return r.stdout
    }
}

/// `$1` Claude folder name (or its 200-character prefix when `$2` = 1), `$3` the rollout cwd needle.
/// Prints `C|X <tab> size <tab> path` per conversation file; reads nothing but listings and rollout prefixes.
let remoteListScript = #"""
c=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
x=${CODEX_HOME:-$HOME/.codex}/sessions
needle=$3
if [ "$2" = 1 ]; then set -- "$c/$1"-*; else set -- "$c/$1"; fi
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
