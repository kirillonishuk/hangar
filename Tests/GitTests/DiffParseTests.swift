import Testing
@testable import Git

@Suite struct DiffParseTests {
    private func hunks(_ d: FileDiff) -> [Hunk] {
        if case .text(let h, _, _) = d { return h }
        return []
    }

    @Test func hunkHeaderForms() {
        let header = "@@ -41,14 +41,29 @@ export async function refresh(token: string)"
        let body = (0..<14).map { " c\($0)" }.joined(separator: "\n") + "\n" + (0..<15).map { "+n\($0)" }.joined(separator: "\n")
        let h = hunks(parseUnifiedDiff("diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n\(header)\n\(body)\n"))
        #expect(h.count == 1)
        #expect(h[0].header == header)
        #expect(h[0].oldStart == 41 && h[0].newStart == 41)

        let one = hunks(parseUnifiedDiff("--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n"))
        #expect(one[0].lines.map(\.kind) == [.deleted, .added])

        let new = hunks(parseUnifiedDiff("--- /dev/null\n+++ b/f\n@@ -0,0 +1,3 @@\n+a\n+b\n+c\n"))
        #expect(new[0].lines.map(\.kind) == [.added, .added, .added])
        #expect(new[0].lines.map(\.newLine) == [1, 2, 3])
        #expect(new[0].lines.allSatisfy { $0.oldLine == nil })
    }

    @Test func lineNumbers() {
        let d = "@@ -41,4 +41,5 @@\n ctx\n-del1\n-del2\n+add1\n+add2\n+add3\n tail\n"
        let l = hunks(parseUnifiedDiff(d))[0].lines
        #expect(l.map(\.kind) == [.context, .deleted, .deleted, .added, .added, .added, .context])
        #expect(l.map(\.oldLine) == [41, 42, 43, nil, nil, nil, 44])
        #expect(l.map(\.newLine) == [41, nil, nil, 42, 43, 44, 45])
    }

    @Test func parserTrustsHunkCounts() {
        let d = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n--- comment\n++++ x\n @@ fake @@\n@@ -10 +10 @@\n-old\n+new\n"
        let h = hunks(parseUnifiedDiff(d))
        #expect(h.count == 2)
        #expect(h[0].lines.map(\.text) == ["-- comment", "+++ x", "@@ fake @@"])
        #expect(h[0].lines.map(\.kind) == [.deleted, .added, .context])
        #expect(h[1].oldStart == 10)
        #expect(h[1].lines.map(\.text) == ["old", "new"])
    }

    @Test func noNewlineMarker() {
        let d = "@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"
        let l = hunks(parseUnifiedDiff(d))[0].lines
        #expect(l.count == 2)
        #expect(l.map(\.noNewlineAtEnd) == [true, true])
    }

    @Test func binaryAndModes() {
        #expect(parseUnifiedDiff("diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n") == .binary)
        #expect(parseUnifiedDiff("diff --git a/x b/x\nold mode 100644\nnew mode 100755\n")
            == .text(hunks: [], oldMode: "100644", newMode: "100755"))
    }

    @Test func combiningMarkAfterPrefixIsContent() {
        let l = hunks(parseUnifiedDiff("@@ -1 +1 @@\n-a\n+\u{301}x\n"))[0].lines
        #expect(l.map(\.kind) == [.deleted, .added])
        #expect(l[1].text == "\u{301}x")
    }
}
