import Foundation
import Testing
@testable import HangarUI

@MainActor @Suite struct PathDisplayTests {
    @Test func abbreviatesHome() {
        #expect(abbreviatedHomePath("/Users/k", home: "/Users/k") == "~")
        #expect(abbreviatedHomePath("/Users/k/Documents/app", home: "/Users/k") == "~/Documents/app")
        #expect(abbreviatedHomePath("/Users/k/", home: "/Users/k/") == "~/")
        #expect(abbreviatedHomePath("/Users/kirill/app", home: "/Users/k") == "/Users/kirill/app")
        #expect(abbreviatedHomePath("/tmp/app", home: "/Users/k") == "/tmp/app")
        #expect(abbreviatedHomePath("", home: "/Users/k") == "")
    }

    @Test func truncatesInTheMiddleKeepingTheLastComponents() {
        let p = "~/Documents/Development/workspace-ai/frontend-cd/.claude/worktrees"
        #expect(middleTruncatedPath(p, maxLength: 100) == p)
        #expect(middleTruncatedPath(p, maxLength: p.count) == p)
        #expect(middleTruncatedPath(p, maxLength: 44) == "~/Documents/…/frontend-cd/.claude/worktrees")
        #expect(middleTruncatedPath(p, maxLength: 34) == "~/…/frontend-cd/.claude/worktrees")
        #expect(middleTruncatedPath(p, maxLength: 21) == "~/…/.claude/worktrees")
        #expect(middleTruncatedPath(p, maxLength: 20) == "~/…/worktrees")
        // Even the last component doesn't fit: its end stays.
        #expect(middleTruncatedPath(p, maxLength: 8) == "…rktrees")
        // More trailing components win over the head.
        #expect(middleTruncatedPath("/Users/k/a/b/c/dddd", maxLength: 14) == "/…/a/b/c/dddd")
        #expect(middleTruncatedPath("/Users/k/a/b/c/dddd", maxLength: 11) == "/…/b/c/dddd")
        #expect(middleTruncatedPath(p, maxLength: 0) == "")
    }

    @Test func panelStartsAtTheNearestExistingFolder() {
        let existing: Set<String> = ["/", "/Users", "/Users/k", "/Users/k/app", "/Users/k/app/.claude"]
        let exists = { existing.contains($0) }
        let fallback = "/Users/k/app/.claude/worktrees"
        // An existing value opens itself.
        #expect(panelStartDirectory("/Users/k/app", fallback: fallback, home: "/Users/k", exists: exists) == "/Users/k/app")
        // A missing one: its nearest existing parent, not the project root.
        #expect(panelStartDirectory("/Users/k/app/.claude/worktrees/x", fallback: fallback, home: "/Users/k", exists: exists) == "/Users/k/app/.claude")
        #expect(panelStartDirectory("~/app/.claude/wt/", fallback: fallback, home: "/Users/k", exists: exists) == "/Users/k/app/.claude")
        // Blank or relative: the default root (or its nearest existing parent).
        #expect(panelStartDirectory("", fallback: fallback, home: "/Users/k", exists: exists) == "/Users/k/app/.claude")
        #expect(panelStartDirectory(" wt ", fallback: fallback, home: "/Users/k", exists: exists) == "/Users/k/app/.claude")
        #expect(panelStartDirectory("/nowhere/deep", fallback: fallback, home: "/Users/k", exists: exists) == "/")
    }
}
