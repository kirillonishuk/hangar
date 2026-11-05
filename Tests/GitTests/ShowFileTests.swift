import Foundation
import Testing
import Exec
@testable import Git

/// `show(rev:path:)`: a file's text at a revision, the original side of the Monaco diff (HD-080).
@Suite struct ShowFileTests {
    @Test func fileAtRevisionOrNil() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try FileManager.default.createDirectory(atPath: t.repo + "/src", withIntermediateDirectories: true)
        try "one\n".write(toFile: t.repo + "/src/a.txt", atomically: true, encoding: .utf8)
        try t.git("add", "-A", in: t.repo)
        try t.git("commit", "-q", "-m", "a", in: t.repo)
        try "two\n".write(toFile: t.repo + "/src/a.txt", atomically: true, encoding: .utf8)
        let git = Git(repo: t.repo)
        #expect(try await git.show(rev: "HEAD", path: "src/a.txt") == "one\n")
        // `./` is relative to the folder git runs in (a subfolder project).
        #expect(try await Git(repo: t.repo + "/src").show(rev: "HEAD", path: "./a.txt") == "one\n")
        #expect(try await git.show(rev: "HEAD", path: "nope.txt") == nil)
        #expect(try await git.show(rev: "HEAD^", path: "src/a.txt") == nil)  // the root commit has no parent
        #expect(try await git.show(rev: "--output=/tmp/x", path: "a") == nil)
    }

    /// `blob(rev:path:maxBytes:)`: raw bytes (an image's old side), nil when missing, over the limit or on a server.
    @Test func blobBytesOrNil() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE, 0x0A] + Array(repeating: 0xC3, count: 200_000))
        try FileManager.default.createDirectory(atPath: t.repo + "/img", withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: t.repo + "/img/a.png"))
        try t.git("add", "-A", in: t.repo)
        try t.git("commit", "-q", "-m", "img", in: t.repo)
        let git = Git(repo: t.repo)
        #expect(try await git.blob(rev: "HEAD", path: "img/a.png", maxBytes: 1 << 20) == bytes)
        #expect(try await Git(repo: t.repo + "/img").blob(rev: "HEAD", path: "./a.png", maxBytes: 1 << 20) == bytes)
        #expect(try await git.blob(rev: "HEAD", path: "img/a.png", maxBytes: 1000) == nil)
        #expect(try await git.blob(rev: "HEAD", path: "nope.png", maxBytes: 1 << 20) == nil)
        #expect(try await git.blob(rev: "--output=/tmp/x", path: "a", maxBytes: 1 << 20) == nil)
        let remote = Git(repo: t.repo, runner: Runner { _, _ in RunResult(status: 0, stdout: "", stderr: "") })
        #expect(try await remote.blob(rev: "HEAD", path: "img/a.png", maxBytes: 1 << 20) == nil)
    }
}
