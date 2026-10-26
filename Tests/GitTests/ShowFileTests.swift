import Foundation
import Testing
@testable import Git

/// `show(rev:path:)`: a file's text at a revision, the original side of the Monaco diff (#80).
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
}
