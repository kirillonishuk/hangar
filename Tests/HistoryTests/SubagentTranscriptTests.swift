import Foundation
import Testing
@testable import History

/// Subagent transcripts as claude writes them (format checked on Claude Code 2.1.314 files, read-only).
@Suite struct SubagentTranscriptTests {
    static func line(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) + "\n"
    }
    static let prompt = line(["type": "user", "isSidechain": true, "agentId": "a1", "message": ["role": "user", "content": "Find the endpoints"]])
    static let meta = line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "<system-reminder>x</system-reminder>"]])
    static let attachment = line(["type": "attachment", "attachment": ["type": "environment"]])
    static let thinking = line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hm"]]]])
    static let call = line(["type": "assistant", "message": ["role": "assistant", "content": [
        ["type": "text", "text": "Looking."],
        ["type": "tool_use", "id": "u1", "name": "Bash", "input": ["command": "rg -n api\nsecond", "description": "Search routes"]],
    ]]])
    static let result = line(["type": "user", "message": ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "u1", "is_error": true, "content": [["type": "text", "text": "exit 1"]]],
    ]]])
    static let handback = line(["type": "assistant", "message": ["role": "assistant", "content": [
        ["type": "tool_use", "id": "u2", "name": "SubagentHandback", "input": ["message": "12 endpoints"]],
    ]]])

    @Test func parsesTheShownSteps() {
        let entries = transcriptEntries(Data(Self.call.utf8)) + transcriptEntries(Data(Self.result.utf8))
            + transcriptEntries(Data(Self.handback.utf8))
        #expect(entries.map(\.0) == [.text, .tool(name: "Bash"), .result(error: true), .report])
        #expect(entries.map(\.1) == ["Looking.", "Search routes", "exit 1", "12 endpoints"])
        for skipped in [Self.meta, Self.attachment, Self.thinking, "garbage\n", "{}\n"] {
            #expect(transcriptEntries(Data(skipped.utf8)).isEmpty)
        }
        let long = Self.line(["type": "assistant", "message": ["content": [["type": "text", "text": String(repeating: "x", count: 9000)]]]])
        #expect(transcriptEntries(Data(long.utf8)).first?.1.count == TranscriptReader.maxText + 1)
    }

    @Test func readsOnlyWhatWasAppended() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hg sub \(UUID().uuidString) ж")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent-a1.jsonl")
        var reader = TranscriptReader()
        #expect(reader.read(url).isEmpty)  // not there yet
        try (Self.prompt + Self.meta + Self.attachment).write(to: url, atomically: false, encoding: .utf8)
        let first = reader.read(url)
        #expect(first.map(\.kind) == [.prompt] && first.first?.text == "Find the endpoints" && first.first?.id == 0)
        // A half-written line waits for its newline.
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        let call = Data(Self.call.utf8)
        try h.write(contentsOf: call.prefix(20))
        #expect(reader.read(url).isEmpty)
        try h.write(contentsOf: call.dropFirst(20))
        try h.close()
        #expect(reader.read(url).map(\.id) == [1, 2])
        #expect(reader.read(url).isEmpty)
        // Replaced by a shorter file: read from the start again.
        try Self.prompt.write(to: url, atomically: true, encoding: .utf8)
        #expect(reader.read(url).map(\.kind) == [.prompt])
    }

    @Test func findsTheTranscriptBySessionAndAgent() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("hg cfg \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let cwd = "/Users/me/Проект x"
        let dir = config.appendingPathComponent("projects/-Users-me--------x/s1/subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        #expect(subagentTranscript(configDir: config, cwd: cwd, session: "s1", agentId: "a1")?.lastPathComponent == "agent-a1.jsonl")
        #expect(subagentTranscript(configDir: config, cwd: cwd, session: "s1", agentId: "agent-a1")?.lastPathComponent == "agent-a1.jsonl")
        // Another folder (a moved worktree's copy) is found too; an unknown agent is not.
        #expect(subagentTranscript(configDir: config, cwd: "/elsewhere", session: "s1", agentId: "a1") != nil)
        #expect(subagentTranscript(configDir: config, cwd: cwd, session: "s1", agentId: "a2") == nil)
    }
}
