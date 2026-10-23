import Foundation
import Testing
@testable import Git

@Suite struct NamingTests {
    @Test(arguments: [
        ("Починить логин", "pochinit-login"),
        ("Rate limit / login", "rate-limit-login"),
        ("Щука  Ёж", "shchuka-ezh"),
        ("Объявления: Хабр", "obyavleniya-khabr"),
        ("fix: API v2.1", "fix-api-v2.1"),
        ("--Café--", "cafe"),
        ("!!!", "task"),
        ("feat/oauth", "feat-oauth"),
        ("", "task"),
        ("Привет", "privet"),
        ("ъь", "task"),
        ("😀", "task"),
        ("a😀b", "a-b"),
        ("a..b", "a.b"),
        ("release.lock", "release"),
        ("a.lock.lock", "a"),
        ("HEAD", "head"),
    ])
    func slugCases(input: String, expected: String) {
        #expect(branchSlug(input) == expected)
    }

    @Test(arguments: [
        ("feat/JS-13333", true), ("fix/JS-1", true), ("Refactor", true), ("a.b_c-d", true), ("x@y", false), ("!!!", false),
        ("Fix login", false), ("feat//x", false), ("a..b", false), ("-x", false), ("x.lock", false),
        ("feat/x.lock", false), ("/x", false), ("x/", false), ("x.", false), (".x", false), ("a/.b", false),
        ("@", false), ("a@{b", false), ("a~b", false), ("a^b", false), ("a:b", false), ("a?b", false),
        ("a*b", false), ("a[b", false), ("a\\b", false), ("a\tb", false), ("a\u{7f}b", false), ("", false),
        ("HEAD", false), ("Привет", false), ("a\u{a0}b", false),
    ])
    func branchNameCases(input: String, expected: Bool) {
        #expect(isBranchName(input) == expected, "\(input.debugDescription)")
    }

    /// Everything `isBranchName` accepts git accepts too.
    @Test func acceptedNamesPassGit() throws {
        let inputs = ["feat/JS-13333", "fix/JS-1", "Refactor", "a.b_c-d", "A/B/C", "v1.2/X_9"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for input in inputs {
            #expect(isBranchName(input))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "check-ref-format", "--branch", input]
            p.currentDirectoryURL = dir
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(input.debugDescription)")
        }
    }

    @Test func worktreeFolderOfSlashBranchIsOneSlug() {
        #expect(worktreePath(projectPath: "/u/dev/shop", root: nil, branch: "feat/JS-13333") == "/u/dev/shop.worktrees/feat-js-13333")
        #expect(worktreePath(projectPath: "/u/dev/shop", root: "/tmp/wt", branch: "feat/JS-13333") == "/tmp/wt/feat-js-13333")
    }

    @Test func worktreePathDefault() {
        #expect(worktreePath(projectPath: "/u/dev/shop-api", root: nil, branch: "feat/oauth") == "/u/dev/shop-api.worktrees/feat-oauth")
        #expect(worktreePath(projectPath: "/u/dev/shop-api/", root: nil, branch: "feat/oauth") == "/u/dev/shop-api.worktrees/feat-oauth")
    }

    @Test func worktreePathRootTrailingSlash() {
        #expect(worktreePath(projectPath: "/u/dev/shop-api", root: "/tmp/wt/", branch: "Fix") == "/tmp/wt/fix")
    }

    @Test func slugIsAlwaysValidBranchName() async throws {
        let inputs = ["", "-x", "..", "a..b", "a...b", "release.lock", "a.lock.lock", "a_.lock", "😀", "Привет", "日本語",
                      "fix/login", "Fix login", " . ", "@{-1}", "a@{b", "HEAD"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for input in inputs {
            let slug = branchSlug(input)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "check-ref-format", "--branch", slug]
            p.currentDirectoryURL = dir
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(input.debugDescription) -> \(slug.debugDescription)")
        }
    }

    @Test func worktreePathCustomRoot() {
        #expect(worktreePath(projectPath: "/u/dev/shop-api", root: "/tmp/wt", branch: "Fix") == "/tmp/wt/fix")
    }
}
