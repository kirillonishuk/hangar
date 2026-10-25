import Foundation
import Testing
@testable import Git

/// `commitFileDiff`: one file of a commit, as the Git tab opens it in the diff tab.
@Suite struct CommitDiffTests {
    private func write(_ t: TempRepo, _ path: String, _ text: String) throws {
        let full = t.repo + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    private func commitAll(_ t: TempRepo, _ message: String) throws {
        try t.git("add", "-A", in: t.repo)
        try t.git("commit", "-q", "--allow-empty", "-m", message, in: t.repo)
    }

    private func head(_ t: TempRepo) throws -> String { try t.git("rev-parse", "HEAD", in: t.repo) }

    private func lines(_ d: FileDiff) -> [String] {
        guard case .text(let hunks, _, _) = d else { return [] }
        return hunks.flatMap(\.lines).map { ($0.kind == .added ? "+" : $0.kind == .deleted ? "-" : " ") + $0.text }
    }

    @Test func modifiedFileAgainstParentNotWorkingTree() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "src/k.txt", "1\n2\n3\n")
        try commitAll(t, "setup")
        try write(t, "src/k.txt", "1\nTWO\n3\n")
        try commitAll(t, "edit")
        let edit = try head(t)
        try write(t, "src/k.txt", "uncommitted\n")  // the working tree must not show
        let d = try await Git(repo: t.repo).commitFileDiff(hash: String(edit.prefix(7)), path: "src/k.txt")
        #expect(lines(d) == [" 1", "-2", "+TWO", " 3"])
    }

    @Test func topRelativePathFromASubfolderAndRename() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "apps/web/old.txt", "a\nb\nc\nd\ne\n")
        try commitAll(t, "setup")
        try t.git("mv", "apps/web/old.txt", "apps/web/new.txt", in: t.repo)
        try commitAll(t, "rename")
        // The Git tab of a subfolder project runs git in the subfolder; commit paths are top-relative.
        let d = try await Git(repo: t.repo + "/apps/web").commitFileDiff(hash: try head(t), path: "apps/web/new.txt", origPath: "apps/web/old.txt")
        guard case .text(let hunks, _, _) = d else { Issue.record("\(d)"); return }
        #expect(hunks.isEmpty)  // a pure rename: no lines
    }

    @Test func rootMergeAndBinary() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let root = try t.git("rev-list", "--max-parents=0", "HEAD", in: t.repo)
        let r = try await Git(repo: t.repo).commitFileDiff(hash: root, path: "a.txt")
        #expect(lines(r).count == 1 && lines(r)[0].hasPrefix("+"))
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try write(t, "f.txt", "feat\n")
        try commitAll(t, "feat")
        try t.commit(file: "m.txt", on: "main")
        try t.git("merge", "-q", "--no-ff", "-m", "merge", "feat", in: t.repo)
        let m = try await Git(repo: t.repo).commitFileDiff(hash: try head(t), path: "f.txt")
        #expect(lines(m) == ["+feat"])  // first parent: what the merge brought in
        try Data([0, 1, 2, 255]).write(to: URL(fileURLWithPath: t.repo + "/b.bin"))
        try commitAll(t, "bin")
        #expect(try await Git(repo: t.repo).commitFileDiff(hash: try head(t), path: "b.bin") == .binary)
        await #expect(throws: GitError.self) { try await Git(repo: t.repo).commitFileDiff(hash: "--all", path: "a.txt") }
    }
}
