import Foundation
import Testing
@testable import Exec

/// A moved worktree's claude conversations (#122): copied to the new folder's place, preferred there on resume.
@Suite struct ClaudeTranscriptTests {
    let id = "0b9e6c55-1f0e-4c1a-9d65-3f1f2d7a8b90"

    @Test func folderNameAsClaude() {
        #expect(claudeProjectFolder("/home/a/frontend-cd/.claude/worktrees/feat_x") == "-home-a-frontend-cd--claude-worktrees-feat-x")
        #expect(claudeProjectFolder("/w/проект 1") == "-w--------1")
    }

    @Test func copiesWithCwdRewriteKeepingTheOriginal() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hg-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = "/w/app/.claude/worktrees/x", new = "/w/app.worktrees/x"
        let source = dir.appendingPathComponent("projects/" + claudeProjectFolder(old))
        try FileManager.default.createDirectory(at: source.appendingPathComponent(id + "/subagents"), withIntermediateDirectories: true)
        try Data("agent".utf8).write(to: source.appendingPathComponent(id + "/subagents/a.jsonl"))
        let lines = [
            #"{"type":"custom-title","title":"t"}"#,
            #"{"parentUuid":null,"cwd":"/w/app/.claude/worktrees/x","message":{"cwd":"/w/app/.claude/worktrees/x"},"z":1}"#,
            #"{"type":"user","cwd":"/elsewhere"}"#,
            "not json",
            #"{"type":"user", "cwd" : "/w/app/.claude/worktrees/x"}"#,  // other formatting: re-encoded
            "",
        ]
        let original = Data(lines.joined(separator: "\n").utf8)
        let file = source.appendingPathComponent(id + ".jsonl")
        #expect(FileManager.default.createFile(atPath: file.path, contents: original, attributes: [.posixPermissions: 0o600]))

        #expect(try copyClaudeTranscript(id: id, from: old, to: new, configDir: dir))
        let copy = dir.appendingPathComponent("projects/" + claudeProjectFolder(new) + "/" + id + ".jsonl")
        let out = try String(contentsOf: copy, encoding: .utf8).components(separatedBy: "\n")
        #expect(out.count == lines.count)
        #expect(out[0] == lines[0] && out[2] == lines[2] && out[3] == lines[3] && out[5] == "")
        // Only the top-level cwd, in place; the nested one and the rest are byte for byte the same.
        #expect(out[1] == #"{"parentUuid":null,"cwd":"/w/app.worktrees/x","message":{"cwd":"/w/app/.claude/worktrees/x"},"z":1}"#)
        let reencoded = try JSONSerialization.jsonObject(with: Data(out[4].utf8)) as? [String: Any]
        #expect(reencoded?["cwd"] as? String == new && reencoded?["type"] as? String == "user")
        #expect(try Data(contentsOf: file) == original)  // the original is untouched
        let perms = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().appendingPathComponent(id + "/subagents/a.jsonl").path))
        #expect(transcriptChoice(id: id, cwd: new, configDir: dir) == .resume)
        #expect(transcriptChoice(id: id, cwd: old, configDir: dir) == .resume)

        // An existing copy is never overwritten; no source: nothing.
        try Data("mine".utf8).write(to: copy)
        #expect(try !copyClaudeTranscript(id: id, from: old, to: new, configDir: dir))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "mine")
        #expect(try !copyClaudeTranscript(id: "other", from: old, to: new, configDir: dir))
    }

    /// The folder named after this cwd wins over any other copy of the same id.
    @Test func choicePrefersTheCwdsOwnFolder() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hg-pref-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cwd = "/zz/new"
        // Sorts first, records another folder: alone it makes the choice `foreign`.
        for (folder, recorded) in [("-0-elsewhere", "/zz/old"), (claudeProjectFolder(cwd), cwd)] {
            let f = dir.appendingPathComponent("projects/" + folder)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            try Data(#"{"type":"user","cwd":"\#(recorded)"}"#.utf8).write(to: f.appendingPathComponent(id + ".jsonl"))
        }
        #expect(transcriptChoice(id: id, cwd: cwd, configDir: dir) == .resume)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("projects/" + claudeProjectFolder(cwd)))
        #expect(transcriptChoice(id: id, cwd: cwd, configDir: dir) == .foreign)
    }
}
