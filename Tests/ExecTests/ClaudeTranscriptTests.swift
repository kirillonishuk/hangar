import Foundation
import Testing
@testable import Exec

/// A relinked worktree's claude conversations (#122): copied at the tab's launch to the new folder's place, preferred there.
@Suite struct ClaudeTranscriptTests {
    let id = "0b9e6c55-1f0e-4c1a-9d65-3f1f2d7a8b90"

    private func temp() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hg-copy-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]))
    }

    private func append(_ text: String, _ url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
    }

    @Test func folderNameAsClaude() {
        #expect(claudeProjectFolder("/home/a/frontend-cd/.claude/worktrees/feat_x") == "-home-a-frontend-cd--claude-worktrees-feat-x")
        #expect(claudeProjectFolder("/w/проект 1") == "-w--------1")
        // Claude shortens long names with a hash: none here.
        #expect(claudeProjectFolder("/" + String(repeating: "a", count: 200)) == nil)
    }

    @Test func copiesWithCwdRewriteKeepingTheOriginal() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = "/w/app/.claude/worktrees/x", new = "/w/app.worktrees/x"
        let source = dir.appendingPathComponent("projects/" + claudeProjectFolder(old)!)
        try write("agent", source.appendingPathComponent(id + "/subagents/a.jsonl"))
        let lines = [
            #"{"type":"custom-title","title":"t"}"#,
            #"{"parentUuid":null,"cwd":"/w/app/.claude/worktrees/x","message":{"cwd":"/w/app/.claude/worktrees/x"},"z":1}"#,
            #"{"type":"user","cwd":"/elsewhere"}"#,
            "not json",
            #"{"type":"user", "cwd" : "/w/app/.claude/worktrees/x"}"#,  // other formatting: re-encoded
            "",
        ]
        let file = source.appendingPathComponent(id + ".jsonl")
        try write(lines.joined(separator: "\n"), file)
        let original = try Data(contentsOf: file)

        #expect(try syncClaudeTranscript(id: id, recordedIn: old, cwd: new, configDir: dir) == .copied)
        let copy = dir.appendingPathComponent("projects/" + claudeProjectFolder(new)! + "/" + id + ".jsonl")
        let out = try String(contentsOf: copy, encoding: .utf8).components(separatedBy: "\n")
        #expect(out.count == lines.count)
        #expect(out[0] == lines[0] && out[2] == lines[2] && out[3] == lines[3] && out[5] == "")
        // Only the top-level cwd, in place; the nested one and the rest are byte for byte the same.
        #expect(out[1] == #"{"parentUuid":null,"cwd":"/w/app.worktrees/x","message":{"cwd":"/w/app/.claude/worktrees/x"},"z":1}"#)
        let reencoded = try JSONSerialization.jsonObject(with: Data(out[4].utf8)) as? [String: Any]
        #expect(reencoded?["cwd"] as? String == new && reencoded?["type"] as? String == "user")
        #expect(try Data(contentsOf: file) == original)  // the original is untouched
        #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
        #expect(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().appendingPathComponent(id + "/subagents/a.jsonl").path))
        #expect(transcriptChoice(id: id, cwd: new, configDir: dir) == .resume)
        #expect(transcriptChoice(id: id, cwd: old, configDir: dir) == .resume)
        #expect(try syncClaudeTranscript(id: id, recordedIn: old, cwd: new, configDir: dir) == .upToDate)
        #expect(try syncClaudeTranscript(id: "other", recordedIn: old, cwd: new, configDir: dir) == .noSource)
    }

    /// Hangar's own copy follows the original's growth; once claude writes to the copy, or when the copy is claude's, it stays.
    @Test func refreshesOwnCopyOnlyWhileClaudeHasNotWrittenToIt() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = "/w/a", new = "/w/b"
        let file = dir.appendingPathComponent("projects/" + claudeProjectFolder(old)! + "/" + id + ".jsonl")
        let copy = dir.appendingPathComponent("projects/" + claudeProjectFolder(new)! + "/" + id + ".jsonl")
        try write(#"{"type":"user","cwd":"/w/a"}"#, file)
        #expect(try syncClaudeTranscript(id: id, recordedIn: old, cwd: new, configDir: dir) == .copied)
        try append("\n" + #"{"type":"assistant","cwd":"/w/a","n":2}"#, file)
        #expect(try syncClaudeTranscript(id: id, recordedIn: old, cwd: new, configDir: dir) == .copied)
        #expect(try String(contentsOf: copy, encoding: .utf8) == #"{"type":"user","cwd":"/w/b"}"# + "\n" + #"{"type":"assistant","cwd":"/w/b","n":2}"#)
        // Claude resumed in the new folder and wrote there: the copy is its now.
        try append("\nmine", copy)
        try append("\n" + #"{"n":3}"#, file)
        #expect(try syncClaudeTranscript(id: id, recordedIn: old, cwd: new, configDir: dir) == .skipped)
        #expect(try String(contentsOf: copy, encoding: .utf8).hasSuffix("mine"))
        // A transcript there that Hangar never made is never touched.
        let other = "/w/c"
        let theirs = dir.appendingPathComponent("projects/" + claudeProjectFolder(other)! + "/" + id + ".jsonl")
        try write("claude's own", theirs)
        #expect(try syncClaudeTranscript(id: id, recordedIn: old, cwd: other, configDir: dir) == .skipped)
        #expect(try String(contentsOf: theirs, encoding: .utf8) == "claude's own")
    }

    /// An interrupted copy's temp file doesn't block the next one, and goes.
    @Test func leftoverTempIsCleanedUp() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("projects/" + claudeProjectFolder("/w/b")!)
        try write("half", target.appendingPathComponent(".\(id).jsonl.hangar-tmp-1234"))
        try write(#"{"cwd":"/w/a"}"#, dir.appendingPathComponent("projects/" + claudeProjectFolder("/w/a")! + "/" + id + ".jsonl"))
        #expect(try syncClaudeTranscript(id: id, recordedIn: "/w/a", cwd: "/w/b", configDir: dir) == .copied)
        let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(names.filter { $0.contains("hangar-tmp") }.isEmpty && names.contains(id + ".jsonl"))
    }

    /// The transcript is found as claude finds it (any folder: a symlinked project's folder was named by the real path),
    /// and the cwd it recorded is the one rewritten.
    @Test func sourceFoundByIdWithItsOwnCwd() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let recorded = "/private/var/real/app/.claude/worktrees/x"
        try write(#"{"type":"user","cwd":"\#(recorded)"}"#, dir.appendingPathComponent("projects/" + claudeProjectFolder(recorded)! + "/" + id + ".jsonl"))
        #expect(try syncClaudeTranscript(id: id, recordedIn: "/link/app/.claude/worktrees/x", cwd: "/link/app.worktrees/x", configDir: dir) == .copied)
        #expect(transcriptChoice(id: id, cwd: "/link/app.worktrees/x", configDir: dir) == .resume)
    }

    /// A folder name claude would shorten: no copy, the old fallback stays.
    @Test func longFolderNameIsSkipped() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"{"cwd":"/w/a"}"#, dir.appendingPathComponent("projects/" + claudeProjectFolder("/w/a")! + "/" + id + ".jsonl"))
        let long = "/" + String(repeating: "b", count: 220)
        #expect(try syncClaudeTranscript(id: id, recordedIn: "/w/a", cwd: long, configDir: dir) == .skipped)
        #expect(transcriptChoice(id: id, cwd: long, configDir: dir) == .foreign)
    }

    /// The folder named after this cwd wins over any other copy of the same id.
    @Test func choicePrefersTheCwdsOwnFolder() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let cwd = "/zz/new"
        // Sorts first, records another folder: alone it makes the choice `foreign`.
        for (folder, recorded) in [("-0-elsewhere", "/zz/old"), (claudeProjectFolder(cwd)!, cwd)] {
            try write(#"{"type":"user","cwd":"\#(recorded)"}"#, dir.appendingPathComponent("projects/" + folder + "/" + id + ".jsonl"))
        }
        #expect(transcriptChoice(id: id, cwd: cwd, configDir: dir) == .resume)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("projects/" + claudeProjectFolder(cwd)!))
        #expect(transcriptChoice(id: id, cwd: cwd, configDir: dir) == .foreign)
    }
}
