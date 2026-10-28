import Exec
import Foundation
import Testing
@testable import History

private let idA = "11111111-1111-4111-8111-111111111111"
private let idB = "22222222-2222-4222-8222-222222222222"
private let idX = "0190a1b2-c3d4-7e5f-8a6b-1c2d3e4f5a6b"
private let idY = "0190a1b2-b3c4-7d5e-9f6a-2b3c4d5e6f7a"

/// Synthetic `~/.claude` and `~/.codex` under a temp home; never the real ones.
private struct Fixture {
    let home: URL
    var claude: URL { home.appendingPathComponent(".claude") }
    var codex: URL { home.appendingPathComponent(".codex") }

    init() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ rel: String, _ lines: [String], mtime: Date? = nil) -> URL {
        let url = home.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        if let mtime { try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

private func claudeUser(_ text: String, ts: String, cwd: String = "/work/proj", branch: String = "main", meta: Bool = false) -> String {
    let content = String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]), encoding: .utf8)!.dropFirst().dropLast()
    return #"{"type":"user","isSidechain":false,"#
        + (meta ? #""isMeta":true,"# : "")
        + #""message":{"role":"user","content":\#(content)},"timestamp":"\#(ts)","cwd":"\#(cwd)","sessionId":"x","gitBranch":"\#(branch)"}"#
}

private func claudeAssistant(ts: String) -> String {
    #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"timestamp":"\#(ts)","cwd":"/work/proj"}"#
}

private let toolResult = #"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"done"}]},"timestamp":"2026-10-20T10:00:03.000Z","cwd":"/work/proj"}"#

private func codexMeta(_ id: String, cwd: String, ts: String, branch: String? = "feature") -> String {
    let git = branch.map { #","git":{"branch":"\#($0)","commit_hash":"abc"}"# } ?? ""
    return #"{"timestamp":"\#(ts)","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(ts)","cwd":"\#(cwd)","originator":"codex_cli_rs","cli_version":"0.1","base_instructions":{"text":"You are Codex."}\#(git)}}"#
}

private func codexEvent(_ type: String, _ message: String, ts: String) -> String {
    #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"\#(type)","message":"\#(message)"}}"#
}

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func writeClaudeFixtures(_ f: Fixture) {
    f.write(".claude/projects/-work-proj/\(idA).jsonl", [
        #"{"type":"mode","mode":"normal","sessionId":"x"}"#,
        claudeUser("<command-name>/clear</command-name>", ts: "2026-10-20T10:00:00.000Z"),
        claudeUser("Caveat: meta", ts: "2026-10-20T10:00:00.500Z", meta: true),
        claudeUser("Fix the login bug\nwith more details", ts: "2026-10-20T10:00:01.000Z"),
        claudeAssistant(ts: "2026-10-20T10:00:02.000Z"),
        toolResult,
        claudeAssistant(ts: "2026-10-20T10:05:00.000Z"),
    ])
    f.write(".claude/projects/-work-proj/\(idB).jsonl", [
        claudeUser("Second chat", ts: "2026-10-21T09:00:00.000Z", branch: "feat/x"),
        claudeAssistant(ts: "2026-10-21T09:01:00.000Z"),
    ])
    // Not conversations of this folder: an invalid id, a sidechain file, a colliding encoding of another cwd, an empty file.
    f.write(".claude/projects/-work-proj/bad id.jsonl", [claudeUser("x", ts: "2026-10-21T09:00:00.000Z")])
    f.write(".claude/projects/-work-proj/agent-1234.jsonl", [claudeUser("x", ts: "2026-10-21T09:00:00.000Z")])
    f.write(".claude/projects/-work-proj/33333333-3333-4333-8333-333333333333.jsonl",
            [claudeUser("other", ts: "2026-10-21T09:00:00.000Z", cwd: "/work-proj")])
    f.write(".claude/projects/-work-proj/44444444-4444-4444-8444-444444444444.jsonl", [#"{"type":"mode","mode":"normal"}"#])
    f.write(".claude/projects/-work-other/55555555-5555-4555-8555-555555555555.jsonl",
            [claudeUser("elsewhere", ts: "2026-10-21T09:00:00.000Z", cwd: "/work/other")])
}

private func writeCodexFixtures(_ f: Fixture) {
    f.write(".codex/sessions/2026/10/19/rollout-2026-10-19T08-00-00-\(idX).jsonl", [
        codexMeta(idX, cwd: "/work/proj", ts: "2026-10-19T08:00:00.000Z"),
        codexEvent("user_message", "<environment_context>x</environment_context>", ts: "2026-10-19T08:00:01.000Z"),
        codexEvent("user_message", "Add a codex test", ts: "2026-10-19T08:00:02.000Z"),
        codexEvent("agent_message", "Done", ts: "2026-10-19T08:00:30.000Z"),
    ])
    f.write(".codex/sessions/2026/10/19/rollout-2026-10-19T09-00-00-\(idY).jsonl", [
        codexMeta(idY, cwd: "/work/other", ts: "2026-10-19T09:00:00.000Z"),
        codexEvent("user_message", "Not here", ts: "2026-10-19T09:00:02.000Z"),
    ])
}

/// Claude Code's own records: `/rename` (`custom-title`, appended again on later turns), its generated title
/// (`ai-title`), a conversation whose first line carries another cwd, and one started in a subfolder of the project.
private func writeRenamedFixtures(_ f: Fixture) {
    let idR = "66666666-6666-4666-8666-666666666666", idT = "77777777-7777-4777-8777-777777777777"
    let idS = "88888888-8888-4888-8888-888888888888"
    f.write(".claude/projects/-work-proj/\(idR).jsonl", [
        #"{"type":"attachment","isSidechain":false,"timestamp":"2026-10-22T08:00:00.000Z","cwd":"/work/app"}"#,
        claudeUser("Look at the crash", ts: "2026-10-22T08:00:01.000Z"),
        #"{"type":"custom-title","customTitle":"First name","sessionId":"\#(idR)"}"#,
        claudeAssistant(ts: "2026-10-22T08:00:02.000Z"),
        #"{"type":"custom-title","customTitle":"Crash in checkout","sessionId":"\#(idR)"}"#,
    ])
    f.write(".claude/projects/-work-proj/\(idT).jsonl", [
        claudeUser("hi there", ts: "2026-10-22T07:00:00.000Z"),
        #"{"type":"ai-title","aiTitle":"Greeting the agent","sessionId":"\#(idT)"}"#,
        claudeAssistant(ts: "2026-10-22T07:00:01.000Z"),
    ])
    f.write(".claude/projects/-work-proj--claude-worktrees-fix/\(idS).jsonl", [
        claudeUser("In a Claude worktree", ts: "2026-10-22T06:00:00.000Z", cwd: "/work/proj/.claude/worktrees/fix"),
        claudeAssistant(ts: "2026-10-22T06:00:01.000Z"),
    ])
    // A sibling folder whose encoded name starts with the project's: not this project.
    f.write(".claude/projects/-work-proj-old/99999999-9999-4999-8999-999999999999.jsonl",
            [claudeUser("old", ts: "2026-10-22T05:00:00.000Z", cwd: "/work/proj-old")])
}

@Suite struct HistoryTests {
    @Test func claudeDirNameEncoding() {
        #expect(claudeProjectDirName("/Users/a/Documents/app") == "-Users-a-Documents-app")
        #expect(claudeProjectDirName("/Users/a/.pane-sessions/x_y") == "-Users-a--pane-sessions-x-y")
        #expect(claudeProjectDirName("/private/tmp/hg proj") == "-private-tmp-hg-proj")
    }

    @Test func titleIsOneTrimmedLine() {
        #expect(conversationTitle("  Fix it\nmore") == "Fix it")
        #expect(conversationTitle("\n\n  second   line  ") == "second line")
        let long = conversationTitle(String(repeating: "word ", count: 40))!
        #expect(long.count == 80)
        #expect(long.hasSuffix("…"))
        #expect(conversationTitle("   ") == nil)
    }

    @Test func listsClaudeAndCodexConversations() async throws {
        let f = Fixture()
        defer { f.remove() }
        writeClaudeFixtures(f)
        writeCodexFixtures(f)
        let history = ConversationHistory()
        let list = await history.local(folder: "/work/proj", claudeDir: f.claude, codexDir: f.codex, open: [idB])
        #expect(list.map(\.id) == [idB, idA, idX])  // newest activity first

        let b = list[0]
        #expect(b.agent == .claude && b.isOpen && b.gitBranch == "feat/x" && b.title == "Second chat")
        #expect(b.messageCount == 2 && !b.messageCountIsEstimate)

        let a = list[1]
        #expect(a.agent == .claude && !a.isOpen)
        #expect(a.title == "Fix the login bug")
        #expect(a.cwd == "/work/proj" && a.gitBranch == "main")
        #expect(a.started == date("2026-10-20T10:00:00Z"))
        #expect(a.lastActivity == date("2026-10-20T10:05:00Z"))
        #expect(a.messageCount == 5)  // the meta line is not a message; the slash command, prompt, tool result and replies are

        let x = list[2]
        #expect(x.agent == .codex && x.title == "Add a codex test" && x.gitBranch == "feature" && x.cwd == "/work/proj")
        #expect(x.started == date("2026-10-19T08:00:00Z") && x.lastActivity == date("2026-10-19T08:00:30Z"))
        #expect(x.messageCount == 3)
    }

    @Test func largeFileReadsOnlyHeadAndTail() async throws {
        let f = Fixture()
        defer { f.remove() }
        var lines = [claudeUser("First prompt", ts: "2026-10-20T10:00:00.000Z")]
        let filler = String(repeating: "x", count: 900)
        for i in 0..<2000 {
            lines.append(#"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"\#(filler)"}]},"timestamp":"2026-10-20T10:\#(String(format: "%02d", i / 60 % 60)):00.000Z","cwd":"/work/proj"}"#)
        }
        lines.append(claudeAssistant(ts: "2026-10-20T12:00:00.000Z"))
        f.write(".claude/projects/-work-proj/\(idA).jsonl", lines)
        let history = ConversationHistory(headBytes: 16_384, tailBytes: 8_192)
        let list = await history.local(folder: "/work/proj", claudeDir: f.claude, codexDir: f.codex, open: [])
        #expect(list.count == 1)
        let c = try #require(list.first)
        #expect(c.title == "First prompt")
        #expect(c.lastActivity == date("2026-10-20T12:00:00Z"))
        #expect(c.messageCountIsEstimate)
        #expect((1500...2500).contains(c.messageCount))
        #expect(await history.bytesRead <= 16_384 + 8_192)
    }

    @Test func cachesByModificationTime() async throws {
        let f = Fixture()
        defer { f.remove() }
        writeClaudeFixtures(f)
        writeCodexFixtures(f)
        let history = ConversationHistory()
        _ = await history.local(folder: "/work/proj", claudeDir: f.claude, codexDir: f.codex, open: [])
        let first = await history.filesParsed
        _ = await history.local(folder: "/work/proj", claudeDir: f.claude, codexDir: f.codex, open: [])
        #expect(await history.filesParsed == first)

        f.write(".claude/projects/-work-proj/\(idB).jsonl", [
            claudeUser("Second chat", ts: "2026-10-21T09:00:00.000Z"),
            claudeAssistant(ts: "2026-10-21T09:01:00.000Z"),
            claudeAssistant(ts: "2026-10-22T09:01:00.000Z"),
        ], mtime: Date().addingTimeInterval(60))
        let list = await history.local(folder: "/work/proj", claudeDir: f.claude, codexDir: f.codex, open: [])
        #expect(await history.filesParsed == first + 1)
        #expect(list.first { $0.id == idB }?.messageCount == 3)
    }

    @Test func remoteThroughRunnerMatchesLocal() async throws {
        let f = Fixture()
        defer { f.remove() }
        writeClaudeFixtures(f)
        writeCodexFixtures(f)
        let home = f.home.path
        // Plays the host: the script runs with the fixture as $HOME (cwd "" = $HOME, like Runner.ssh).
        let runner = Runner { args, _ in
            try await Runner.local.run(["-u", "CLAUDE_CONFIG_DIR", "-u", "CODEX_HOME", "HOME=\(home)"] + args, home)
        }
        let local = await ConversationHistory().local(folder: "/work/proj", claudeDir: f.claude, codexDir: f.codex, open: [idA])
        let history = ConversationHistory()
        let remote = try await history.remote(folder: "/work/proj", host: "dev", runner: runner, open: [idA])
        #expect(remote == local)
        let parsed = await history.filesParsed
        _ = try await history.remote(folder: "/work/proj", host: "dev", runner: runner, open: [idA])
        #expect(await history.filesParsed == parsed)
    }

    @Test func remoteFailureThrows() async {
        let runner = Runner { _, _ in RunResult(status: 255, stdout: "", stderr: "boom") }
        await #expect(throws: HistoryError.self) {
            try await ConversationHistory().remote(folder: "/work/proj", host: "dev", runner: runner, open: [])
        }
    }

    @Test func renamedAndSubfolderConversationsAreListed() async throws {
        let f = Fixture()
        defer { f.remove() }
        writeClaudeFixtures(f)
        writeRenamedFixtures(f)
        let list = await ConversationHistory().local(folder: "/work/proj", claudeDir: f.claude, codexDir: f.codex, open: [])
        #expect(list.map(\.title) == ["Crash in checkout", "Greeting the agent", "In a Claude worktree", "Second chat", "Fix the login bug"])
        #expect(list[0].cwd == "/work/proj")
        #expect(list[2].cwd == "/work/proj/.claude/worktrees/fix")

        let home = f.home.path
        let runner = Runner { args, _ in
            try await Runner.local.run(["-u", "CLAUDE_CONFIG_DIR", "-u", "CODEX_HOME", "HOME=\(home)"] + args, home)
        }
        #expect(try await ConversationHistory().remote(folder: "/work/proj", host: "dev", runner: runner, open: []) == list)
    }
}
