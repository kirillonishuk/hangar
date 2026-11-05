import AppKit
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// HD-147: «Просмотрено» marks of the Changes list and the rendered «Просмотр» of HTML / Markdown / SVG diffs.
@MainActor @Suite struct DiffReviewTests {
    @Test func nextUnviewedWrapsAndSkipsViewed() {
        let files = ["a", "b", "c", "d"]
        #expect(nextUnviewed(files, after: "b", viewed: ["b"]) == "c")
        #expect(nextUnviewed(files, after: "b", viewed: ["b", "c"]) == "d")
        // Past the end: from the top.
        #expect(nextUnviewed(files, after: "d", viewed: ["d", "a"]) == "b")
        #expect(nextUnviewed(files, after: "c", viewed: ["a", "b", "c", "d"]) == nil)
        // Only the current one left unviewed (it was just unmarked elsewhere): nothing else to open.
        #expect(nextUnviewed(files, after: "c", viewed: ["a", "b", "d"]) == nil)
        // A path no longer listed: from the top.
        #expect(nextUnviewed(files, after: "gone", viewed: ["a"]) == "b")
        #expect(nextUnviewed([], after: "a", viewed: []) == nil)
    }

    @Test func markFollowsTheFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar viewed \(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("one".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: dir.appendingPathComponent("b.txt"))
        let files = [ChangedFile(path: "a.txt", change: .modified, added: 1, deleted: 1),
                     ChangedFile(path: "b.txt", change: .modified, added: 1, deleted: 1)]
        let stamp = { (f: ChangedFile) in viewStamp(f, from: "base", root: dir.path) }
        let marks = ["a.txt": stamp(files[0]), "b.txt": stamp(files[1])]
        #expect(viewedPaths(marks, files: files, stamp: stamp) == ["a.txt", "b.txt"])
        // Rewritten after marking: the mark is gone; the other file keeps its.
        try Data("one, edited".utf8).write(to: dir.appendingPathComponent("a.txt"))
        #expect(viewedPaths(marks, files: files, stamp: stamp) == ["b.txt"])
        // Another base (⌥B, a moved merge-base) is another diff.
        #expect(viewedPaths(marks, files: files) { viewStamp($0, from: "other", root: dir.path) }.isEmpty)
        // A file that left the list is not counted.
        #expect(viewedPaths(marks, files: [files[1]], stamp: stamp) == ["b.txt"])
    }

    /// On a server the line counts stand in for the file; an untracked file's late count doesn't drop its mark.
    @Test func remoteStampUsesCounts() {
        let file = ChangedFile(path: "a.swift", change: .modified, added: 2, deleted: 0)
        var edited = file
        edited.added = 3
        #expect(viewStamp(file, from: "x", root: nil) != viewStamp(edited, from: "x", root: nil))
        let untracked = ChangedFile(path: "n.swift", change: .untracked)
        var counted = untracked
        counted.added = 12
        #expect(viewStamp(untracked, from: "x", root: nil) == viewStamp(counted, from: "x", root: nil))
    }

    @Test func viewedKeyIsOptionV() {
        #expect(diffKeyRoute(keyCode: 9, modifiers: .option, diffActive: true, editingText: false, webFocused: true) == .toggleViewed)
        #expect(diffKeyRoute(keyCode: 9, modifiers: .option, diffActive: false, editingText: false) == nil)
        #expect(diffKeyRoute(keyCode: 9, modifiers: [], diffActive: true, editingText: false) == nil)
    }

    @Test func previewEligibility() {
        #expect(previewEligible(path: "docs/mockup.html", isText: true, local: true))
        #expect(previewEligible(path: "README.MD", isText: true, local: true))
        #expect(previewEligible(path: "icon.svg", isText: true, local: true))
        #expect(!previewEligible(path: "icon.svg", isText: true, local: false))  // a server's project
        #expect(!previewEligible(path: "page.html", isText: false, local: true))  // too large, binary
        #expect(!previewEligible(path: "main.swift", isText: true, local: true))
        #expect(!previewEligible(path: "html", isText: true, local: true))
    }

    @Test func markdownBecomesHTMLWithoutRawMarkup() {
        let html = markdownHTML("# Title\n\nSome *em* and `x<y`\n\n- one\n- two\n\n```\na < b\n```\n\n<script>alert(1)</script>\n\n[go](https://example.com)")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<code>x&lt;y</code>"))
        #expect(html.contains("<ul><li><p>one</p></li><li><p>two</p></li></ul>"))
        #expect(html.contains("<pre><code>a &lt; b\n</code></pre>"))
        #expect(!html.contains("<script"))
        #expect(html.contains("<a href=\"https://example.com\">go</a>"))
    }

    /// Relative links of a page reach the project's files and nothing outside it.
    @Test func previewAssetsStayInTheProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar preview \(UUID())")
        let root = dir.appendingPathComponent("proj").path
        try FileManager.default.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a{}".utf8).write(to: URL(fileURLWithPath: root + "/docs/common.css"))
        try Data("secret".utf8).write(to: dir.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(atPath: root + "/docs/link.txt", withDestinationPath: dir.appendingPathComponent("outside.txt").path)
        let base = previewBase(dir: "docs")
        let css = try #require(URL(string: "common.css", relativeTo: base)?.absoluteURL)
        #expect(previewAssetPath(css, root: root)?.hasSuffix("/proj/docs/common.css") == true)
        let up = try #require(URL(string: "../../outside.txt", relativeTo: base)?.absoluteURL)
        // URL resolution clamps `..` at the host: it lands in the project root, never above it.
        #expect(previewAssetPath(up, root: root)?.hasSuffix("/proj/outside.txt") == true)
        let raw = try #require(URL(string: "hangar-preview://page/docs/%2E%2E/%2E%2E/outside.txt"))
        #expect(previewAssetPath(raw, root: root) == nil)  // an encoded `..` the page could send itself
        let link = try #require(URL(string: "link.txt", relativeTo: base)?.absoluteURL)
        #expect(previewAssetPath(link, root: root) == nil)
        let file = try #require(URL(string: "file:///etc/hosts"))
        #expect(previewAssetPath(file, root: root) == nil)
    }

    /// A modified page: «Было» from git, «Стало» from the disk; an added one — just the new page.
    @Test func previewSidesComeFromGitAndDisk() async throws {
        let repo = try await TempRepo.offMain()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-preview-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { repo.cleanup(); try? FileManager.default.removeItem(at: dir) }
        try Data("<p>old</p>".utf8).write(to: URL(fileURLWithPath: repo.repo + "/page.html"))
        try await repo.git("add", "page.html", in: repo.repo)
        try await repo.git("commit", "-q", "-m", "page", in: repo.repo)
        try Data("<p>new</p>".utf8).write(to: URL(fileURLWithPath: repo.repo + "/page.html"))
        try Data("# Hi".utf8).write(to: URL(fileURLWithPath: repo.repo + "/notes.md"))
        var s = WorkspaceState()
        let t = s.addTask(projectId: s.addProject(name: "app", path: repo.repo), name: "a")
        _ = s.addTab(taskId: t, kind: .shell)
        s.select(taskId: t)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        func settle() async { while let task = app.inspector.loading { await task.value } }
        app.inspector.show(taskId: t, root: repo.repo, baseBranch: { nil })
        await settle()

        app.openDiff(path: "page.html")
        await settle()
        let pageTab = try #require(app.activeDiff)
        let page = try #require(await app.diffPreviewSides(pageTab))
        #expect(page.sides.map(\.title) == [L10n.diffImageBefore, L10n.diffImageAfter])
        #expect(page.sides.map { String(decoding: $0.page, as: UTF8.self) } == ["<p>old</p>", "<p>new</p>"])
        #expect(page.root == repo.repo && page.dir == "")

        app.openDiff(path: "notes.md")
        await settle()
        let notesTab = try #require(app.activeDiff)
        let notes = try #require(await app.diffPreviewSides(notesTab))
        #expect(notes.sides.count == 1 && notes.sides[0].title == nil)
        #expect(String(decoding: notes.sides[0].page, as: UTF8.self).contains("<h1>Hi</h1>"))

        // «Просмотрено» on notes.md opens the next unviewed file and survives until the file changes.
        app.toggleDiffViewed()
        #expect(app.viewedChanges == ["notes.md"])
        #expect(app.activeDiff?.path == "page.html")
        app.toggleDiffViewed()
        #expect(app.viewedChanges == ["notes.md", "page.html"])
        #expect(app.activeDiff?.path == "page.html")  // nothing left to open: stays
        try Data("# Hi there".utf8).write(to: URL(fileURLWithPath: repo.repo + "/notes.md"))
        #expect(app.viewedChanges == ["page.html"])
        app.toggleDiffViewed()  // unmark the shown file
        #expect(app.viewedChanges.isEmpty)
    }

    /// An editor file's page reaches the chat's folder when the file is inside it, else only its own folder.
    @Test func renderRootIsTheChatFolderWhenInside() {
        #expect(renderRoot(path: "/r/app/docs/a.html", cwd: "/r/app") == ("/r/app", "docs"))
        #expect(renderRoot(path: "/r/app/a.md", cwd: "/r/app") == ("/r/app", ""))
        #expect(renderRoot(path: "/r/application/a.md", cwd: "/r/app") == ("/r/application", ""))
        #expect(renderRoot(path: "/x/a.svg", cwd: nil) == ("/x", ""))
    }
}
