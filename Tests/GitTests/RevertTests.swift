import Exec
import Foundation
import Testing
@testable import Git

/// File revert (HD-156) on real temp repos: what git ends up with, what goes to the (fake) Trash, and that undo
/// puts the bytes back.
@Suite struct RevertTests {
    private struct Fixture {
        let t: TempRepo
        let backups: String
        let trashDir: String
        var g: Git { Git(repo: t.repo) }

        init() throws {
            t = try TempRepo()
            backups = t.root + "/backups"
            trashDir = t.root + "/trash"
            try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
            // Committed: «tracked file.txt» (space) and «файл.txt» (Cyrillic) beside a.txt.
            try write("tracked file.txt", "one\ntwo\n")
            try write("файл.txt", "раз\n")
            try t.git("add", ".", in: t.repo)
            try t.git("commit", "-q", "-m", "files", in: t.repo)
        }

        func write(_ path: String, _ text: String) throws {
            let full = t.repo + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        }

        func read(_ path: String) -> String? {
            FileManager.default.contents(atPath: t.repo + "/" + path).map { String(decoding: $0, as: UTF8.self) }
        }

        func status() throws -> String { try t.git("status", "--porcelain", "--untracked-files=all", in: t.repo) }

        func revert(_ path: String, origPath: String? = nil) async throws -> RevertBackup {
            try await g.revertFile(path, origPath: origPath, backupRoot: backups) { url in
                try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: trashDir + "/" + url.lastPathComponent))
            }
        }

        var trashed: [String] { (try? FileManager.default.contentsOfDirectory(atPath: trashDir)) ?? [] }
    }

    @Test func modifiedWithSpaceComesBackAndUndoes() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("tracked file.txt", "one\nTWO\nthree\n")
        let backup = try await f.revert("tracked file.txt")
        #expect(f.read("tracked file.txt") == "one\ntwo\n")
        #expect(try f.status().isEmpty)
        #expect(FileManager.default.fileExists(atPath: backup.dir + "/backup.json"))
        try backup.undo()
        #expect(f.read("tracked file.txt") == "one\nTWO\nthree\n")
    }

    @Test func stagedAndModifiedCyrillic() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("файл.txt", "staged\n")
        try f.t.git("add", "файл.txt", in: f.t.repo)
        try f.write("файл.txt", "staged\nand more\n")
        let backup = try await f.revert("файл.txt")
        #expect(f.read("файл.txt") == "раз\n")
        #expect(try f.status().isEmpty)  // the index is back to HEAD too
        try backup.undo()
        #expect(f.read("файл.txt") == "staged\nand more\n")
    }

    @Test func deletedComesBackAndUndoRemovesIt() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try FileManager.default.removeItem(atPath: f.t.repo + "/tracked file.txt")
        let backup = try await f.revert("tracked file.txt")
        #expect(f.read("tracked file.txt") == "one\ntwo\n")
        #expect(backup.entries.map(\.saved) == [nil])
        try backup.undo()
        #expect(f.read("tracked file.txt") == nil)
    }

    @Test func stagedDeletion() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.t.git("rm", "-q", "файл.txt", in: f.t.repo)
        _ = try await f.revert("файл.txt")
        #expect(f.read("файл.txt") == "раз\n")
        #expect(try f.status().isEmpty)
    }

    @Test func untrackedGoesToTrashAndUndoBringsItBack() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("new dir/новый файл.txt", "fresh\n")
        let backup = try await f.revert("new dir/новый файл.txt")
        #expect(f.read("new dir/новый файл.txt") == nil)
        #expect(f.trashed == ["новый файл.txt"])
        try backup.undo()
        #expect(f.read("new dir/новый файл.txt") == "fresh\n")
    }

    @Test func stagedNewIsUnstagedAndTrashed() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("added.txt", "a\n")
        try f.t.git("add", "added.txt", in: f.t.repo)
        try f.write("added.txt", "a\nb\n")  // staged, then edited again
        let backup = try await f.revert("added.txt")
        #expect(f.read("added.txt") == nil)
        #expect(f.trashed == ["added.txt"])
        #expect(try f.status().isEmpty)
        try backup.undo()
        #expect(f.read("added.txt") == "a\nb\n")
        #expect(try f.status() == "?? added.txt")  // back as a file, no longer staged
    }

    /// The agent writes the file between the snapshot and its revert: that write is left in place, not lost.
    @Test func writeDuringTheRevertIsKept() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("added.txt", "a\n")
        try f.t.git("add", "added.txt", in: f.t.repo)
        let full = f.t.repo + "/added.txt"
        let racing = Runner(isLocal: true) { args, cwd in
            let r = try await Runner.local.run(args, cwd)
            if args.contains("rm") { try Data("agent\n".utf8).write(to: URL(fileURLWithPath: full)) }
            return r
        }
        do {
            _ = try await Git(repo: f.t.repo, runner: racing).revertFile("added.txt", backupRoot: f.backups) { _ in Issue.record("trashed") }
            Issue.record("no error")
        } catch let RevertError.changedWhileReverting(dir, path) {
            #expect(path == "added.txt" && FileManager.default.fileExists(atPath: dir + "/0-added.txt"))
        }
        #expect(f.read("added.txt") == "agent\n")
    }

    @Test func stagedRenameRevertsBothSides() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.t.git("mv", "tracked file.txt", "renamed.txt", in: f.t.repo)
        let backup = try await f.revert("renamed.txt", origPath: "tracked file.txt")
        #expect(f.read("tracked file.txt") == "one\ntwo\n")
        #expect(f.read("renamed.txt") == nil)
        #expect(try f.status().isEmpty)
        try backup.undo()
        #expect(f.read("renamed.txt") == "one\ntwo\n")
        #expect(f.read("tracked file.txt") == nil)
    }

    @Test func subfolderProjectUsesRelativePaths() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("apps/web/x.txt", "x\n")
        try f.t.git("add", ".", in: f.t.repo)
        try f.t.git("commit", "-q", "-m", "x", in: f.t.repo)
        try f.write("apps/web/x.txt", "changed\n")
        let sub = Git(repo: f.t.repo + "/apps/web")
        _ = try await sub.revertFile("x.txt", backupRoot: f.backups) { _ in Issue.record("nothing to trash") }
        #expect(f.read("apps/web/x.txt") == "x\n")
    }

    @Test func refusesFolderAndNothing() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try FileManager.default.createDirectory(atPath: f.t.repo + "/dir", withIntermediateDirectories: true)
        await #expect(throws: RevertError.notAFile("dir")) { _ = try await f.revert("dir") }
        await #expect(throws: RevertError.nothingToRevert) { _ = try await f.revert("missing.txt") }
        #expect(!FileManager.default.fileExists(atPath: f.backups))  // refused before any snapshot
    }

    /// An agent wrote the file after the revert: «Вернуть» refuses and leaves both its write and the snapshot.
    @Test func undoRefusesAfterANewWrite() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("tracked file.txt", "mine\n")
        let backup = try await f.revert("tracked file.txt")
        try f.write("tracked file.txt", "agent\n")
        #expect(throws: RevertError.changedSince(f.t.repo + "/tracked file.txt")) { try backup.undo() }
        #expect(f.read("tracked file.txt") == "agent\n")
        // A trashed new file whose path got a new folder meanwhile: the folder is not removed.
        try f.write("new.txt", "n\n")
        let second = try await f.revert("new.txt")
        try FileManager.default.createDirectory(atPath: f.t.repo + "/new.txt", withIntermediateDirectories: true)
        #expect(throws: RevertError.changedSince(f.t.repo + "/new.txt")) { try second.undo() }
        #expect(FileManager.default.fileExists(atPath: f.t.repo + "/new.txt"))
    }

    /// A symlink is snapshotted as a link (not its target) and comes back as one; what undo replaces is kept aside.
    @Test func symlinkRoundTrip() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try FileManager.default.createDirectory(atPath: f.t.root + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.t.repo + "/link", withDestinationPath: f.t.root + "/elsewhere")
        let backup = try await f.revert("link")
        #expect(!itemExists(f.t.repo + "/link") && FileManager.default.fileExists(atPath: f.t.root + "/elsewhere"))
        try backup.undo()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.t.repo + "/link") == f.t.root + "/elsewhere")
    }

    @Test func undoKeepsTheReplacedCopy() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("tracked file.txt", "mine\n")
        let backup = try await f.revert("tracked file.txt")
        try backup.undo()
        #expect(f.read("tracked file.txt") == "mine\n")
        #expect(FileManager.default.contents(atPath: backup.dir + "/replaced-0-tracked file.txt") == Data("one\ntwo\n".utf8))
    }

    /// The Trash failed after the snapshot: the error names the snapshot folder.
    @Test func failureAfterSnapshotNamesIt() async throws {
        let f = try Fixture(); defer { f.t.cleanup() }
        try f.write("new.txt", "n\n")
        struct NoTrash: Error {}
        do {
            _ = try await f.g.revertFile("new.txt", backupRoot: f.backups) { _ in throw NoTrash() }
            Issue.record("no error")
        } catch let RevertError.afterSnapshot(dir, _) {
            #expect(FileManager.default.contents(atPath: dir + "/0-new.txt") == Data("n\n".utf8))
        }
    }

    @Test func pruneDropsOldSnapshotsOnly() throws {
        let root = NSTemporaryDirectory() + "hangar-revert-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/old", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/new", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -10 * 24 * 3600)], ofItemAtPath: root + "/old")
        RevertBackup.prune(root, olderThan: 7 * 24 * 3600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["new"])
    }
}
