import Exec
import Foundation

/// A subagent's transcript, `<config>/projects/<cwd folder>/<session>/subagents/agent-<id>.jsonl` (the folder claude names
/// after `cwd` first, then any — ids are unique, as `transcriptChoice`). Both ids are validated at the trust boundary;
/// nil — no such file yet (a subagent that just started, a folder claude shortens).
public func subagentTranscript(configDir: URL, cwd: String, session: String, agentId: String) -> URL? {
    let projects = configDir.appendingPathComponent("projects")
    let fm = FileManager.default
    let own = [cwd, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path].compactMap(claudeProjectFolder)
    let folders = own + ((try? fm.contentsOfDirectory(atPath: projects.path)) ?? []).filter { !own.contains($0) }
    // The docs show `agent_id` both bare and `agent-…`; the file is `agent-<bare id>.jsonl`.
    let bare = agentId.hasPrefix("agent-") ? String(agentId.dropFirst(6)) : agentId
    for folder in folders {
        let dir = projects.appendingPathComponent(folder).appendingPathComponent(session).appendingPathComponent("subagents")
        for name in ["agent-\(bare).jsonl", "\(agentId).jsonl"] where fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            return dir.appendingPathComponent(name)
        }
    }
    return nil
}

/// One shown step of a subagent's transcript.
public struct TranscriptEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A user-side message: the orchestrator's prompt first, later a hook's or the user's.
        case prompt
        /// The subagent's own text.
        case text
        /// A tool call: `name` and a one-line summary of its input.
        case tool(name: String)
        /// A tool's result; `error` — it failed.
        case result(error: Bool)
        /// Its final report (`SubagentHandback`).
        case report
    }

    public var id: Int
    public var kind: Kind
    public var text: String
}

/// Reads a transcript incrementally: each `read` parses only the complete lines appended since the last one.
public struct TranscriptReader: Sendable {
    /// Characters kept per entry: a long result or file body is cut, the viewer is not a file reader.
    public static let maxText = 4000
    /// Bytes read at most per call: a huge transcript shows its start, then catches up on the next change.
    static let maxChunk = 8 << 20

    private var offset: UInt64 = 0
    private var next = 0

    public init() {}

    /// New entries since the last call; [] when the file is missing or nothing complete was appended.
    public mutating func read(_ url: URL) -> [TranscriptEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        // A shorter file was replaced: start over.
        if let end = try? handle.seekToEnd(), end < offset { offset = 0; next = 0 }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: Self.maxChunk), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        var out: [TranscriptEntry] = []
        for line in complete.split(separator: 0x0A) {
            for (kind, text) in transcriptEntries(Data(line)) {
                out.append(TranscriptEntry(id: next, kind: kind, text: text))
                next += 1
            }
        }
        return out
    }
}

/// The shown entries of one transcript line: user/assistant messages only (attachments, thinking, request records are not).
func transcriptEntries(_ line: Data) -> [(TranscriptEntry.Kind, String)] {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let type = object["type"] as? String, type == "user" || type == "assistant",
          object["isMeta"] as? Bool != true,
          let message = object["message"] as? [String: Any] else { return [] }
    func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > TranscriptReader.maxText ? String(t.prefix(TranscriptReader.maxText)) + "…" : t
    }
    if let text = message["content"] as? String {
        let t = clip(text)
        return t.isEmpty ? [] : [(type == "user" ? .prompt : .text, t)]
    }
    guard let blocks = message["content"] as? [[String: Any]] else { return [] }
    var out: [(TranscriptEntry.Kind, String)] = []
    for block in blocks {
        switch block["type"] as? String {
        case "text":
            let t = clip(block["text"] as? String ?? "")
            if !t.isEmpty { out.append((type == "user" ? .prompt : .text, t)) }
        case "tool_use":
            let name = block["name"] as? String ?? "?"
            let input = block["input"] as? [String: Any] ?? [:]
            if name == "SubagentHandback", let report = input["message"] as? String {
                out.append((.report, clip(report)))
            } else {
                out.append((.tool(name: String(name.prefix(64))), toolSummary(input)))
            }
        case "tool_result":
            out.append((.result(error: block["is_error"] as? Bool == true), clip(resultText(block["content"]))))
        default: break
        }
    }
    return out
}

/// The input field that says what a call does, first line: a command, a path, a pattern, a description.
func toolSummary(_ input: [String: Any]) -> String {
    for key in ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "skill"] {
        if let s = input[key] as? String, let line = s.split(whereSeparator: \.isNewline).first {
            return String(line.prefix(300))
        }
    }
    return ""
}

private func resultText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    guard let blocks = content as? [[String: Any]] else { return "" }
    return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
}
