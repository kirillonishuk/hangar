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
        for input in inputs {
            let slug = branchSlug(input)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "check-ref-format", "--branch", slug]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(input.debugDescription) -> \(slug.debugDescription)")
        }
    }

    @Test func worktreePathCustomRoot() {
        #expect(worktreePath(projectPath: "/u/dev/shop-api", root: "/tmp/wt", branch: "Fix") == "/tmp/wt/fix")
    }
}
