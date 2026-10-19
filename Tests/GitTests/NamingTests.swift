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
    ])
    func slugCases(input: String, expected: String) {
        #expect(branchSlug(input) == expected)
    }

    @Test func worktreePathDefault() {
        #expect(worktreePath(projectPath: "/u/dev/shop-api", root: nil, branch: "feat/oauth") == "/u/dev/shop-api.worktrees/feat-oauth")
        #expect(worktreePath(projectPath: "/u/dev/shop-api/", root: nil, branch: "feat/oauth") == "/u/dev/shop-api.worktrees/feat-oauth")
    }

    @Test func worktreePathCustomRoot() {
        #expect(worktreePath(projectPath: "/u/dev/shop-api", root: "/tmp/wt", branch: "Fix") == "/tmp/wt/fix")
    }
}
