import Foundation
import Testing
import Git
@testable import HangarUI
import Workspace

/// The toolbar's branch switcher (spec design-system §3.2, #114): lists, what is inactive, the note, refusals.
@MainActor @Suite struct BranchSwitcherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func b(_ name: String, remote: Bool = false, days: Double) -> Branch {
        Branch(name: name, isRemote: remote, lastCommit: now.addingTimeInterval(-days * 86_400))
    }

    private func choices(head: Head? = .branch("feat/discount"), uncommitted: Int = 0, elsewhere: [String: String] = [:]) -> BranchChoices {
        BranchChoices(head: head, local: [b("main", days: 0.5), b("feat/discount", days: 1), b("chore/vite", days: 3), b("old", days: 9)],
                      remote: [b("origin/main", remote: true, days: 0.5), b("origin/release-2.4", remote: true, days: 5)],
                      uncommitted: uncommitted, elsewhere: elsewhere)
    }

    private func entries(_ c: BranchChoices?, query: String = "", creating: Bool = false, busy: Bool = false) -> [PopoverMenuEntry] {
        branchSwitcherEntries(c, query: query, creating: creating, busy: busy, now: now, switchTo: { _ in }, startCreating: {}, create: { _ in })
    }

    private func items(_ e: [PopoverMenuEntry]) -> [PopoverMenuItem] { e.compactMap(\.item) }

    @Test func currentFirstThenRecentLocalThenRemote() {
        let rows = branchSwitcherRows(choices(), query: "")
        #expect(rows.local.map(\.name) == ["feat/discount", "main", "chore/vite", "old"])
        #expect(rows.remote.map(\.name) == ["origin/main", "origin/release-2.4"])
        let e = entries(choices())
        #expect(e.first == .header(L10n.switcherLocal))
        #expect(e.contains(.header(L10n.switcherRemote)))
        let current = items(e)[0]
        #expect(current.checked && current.note == L10n.branchCurrent && current.mono)
        #expect(items(e).last?.title == L10n.branchNewFrom("feat/discount"))
    }

    @Test func searchFiltersCaseInsensitiveAndOffersToCreate() {
        let rows = branchSwitcherRows(choices(), query: " MAIN ")
        #expect(rows.local.map(\.name) == ["main"])
        #expect(rows.remote.map(\.name) == ["origin/main"])
        // An existing local name: no create row.
        #expect(!items(entries(choices(), query: "main")).contains { $0.title.contains(L10n.branchCreate) })
        // Nothing matches: only «Создать ветку <текст>», which runs with the menu open.
        let none = items(entries(choices(), query: "feat/new"))
        #expect(none.map(\.title) == [L10n.branchCreateNamed("feat/new")])
        #expect(none[0].keepsOpen && none[0].enabled)
    }

    /// A remote branch by its full or short name is not offered as a new one; the short name lists the remote to track.
    @Test func noCreateRowForRemoteNames() {
        #expect(branchNameTaken(choices(), "origin/main"))
        #expect(branchNameTaken(choices(), "release-2.4"))
        #expect(branchNameTaken(choices(), "main"))
        #expect(!branchNameTaken(choices(), "feat/new"))
        for q in ["origin/main", "release-2.4"] {
            #expect(!items(entries(choices(), query: q)).contains { $0.title.contains(L10n.branchCreate) })
        }
        let release = items(entries(choices(), query: "release-2.4"))
        #expect(release.map(\.title) == ["origin/release-2.4"] && release[0].enabled)
    }

    /// A project in a subfolder: the count is the repository's, and the note says so.
    @Test func subfolderSaysRepositoryWide() {
        var c = choices(uncommitted: 3)
        c.subfolder = true
        #expect(branchSwitcherNote(c, loadError: nil, creating: false, progress: nil, refusal: nil)?.lead == L10n.branchDirtyRepo(L10n.fileCount(3)))
        #expect(branchRefusalNote(BranchSwitchError.dirty(files: 3), text: "", subfolder: true).lead == L10n.branchDirtyRepo(L10n.fileCount(3)))
    }

    @Test func dirtyTreeDisablesSwitchingButNotNewBranch() {
        let e = items(entries(choices(uncommitted: 4)))
        let switches = e.filter { $0.mono && !$0.checked }
        #expect(!switches.isEmpty && switches.allSatisfy { !$0.enabled && $0.help == L10n.branchDirtyHint })
        #expect(e.first { $0.checked }?.enabled == true)
        #expect(e.last?.enabled == true)
        let note = branchSwitcherNote(choices(uncommitted: 4), loadError: nil, creating: false, progress: nil, refusal: nil)
        #expect(note == PopoverMenuNote(lead: L10n.branchDirty(L10n.fileCount(4)), text: L10n.branchDirtyHint + " " + L10n.branchDirtyNewHint, tone: .waiting))
        #expect(branchSwitcherNote(choices(), loadError: nil, creating: false, progress: nil, refusal: nil) == nil)
    }

    @Test func branchOpenElsewhereIsInactiveWithItsChat() {
        let e = items(entries(choices(elsewhere: ["chore/vite": "перевод на Vite", "old": "/tmp/copy"])))
        let vite = e.first { $0.title == "chore/vite" }
        #expect(vite?.enabled == false && vite?.note == L10n.branchInChatNote("перевод на Vite"))
        #expect(e.first { $0.title == "old" }?.note == L10n.branchInFolderNote)
        #expect(e.first { $0.title == "main" }?.enabled == true)
    }

    @Test func busyDisablesEverythingAndShowsProgress() {
        #expect(items(entries(choices(), busy: true)).allSatisfy { !$0.enabled })
        let note = branchSwitcherNote(choices(), loadError: nil, creating: false, progress: L10n.branchSwitching("main"),
                                      refusal: PopoverMenuNote(text: "x", tone: .failed))
        #expect(note?.busy == true && note?.text == L10n.branchSwitching("main"))
        #expect(branchSwitcherNote(nil, loadError: nil, creating: false, progress: nil, refusal: nil)?.busy == true)
        #expect(branchSwitcherNote(nil, loadError: "host is not connected", creating: false, progress: nil, refusal: nil)?.tone == .failed)
    }

    @Test func newBranchStepStartsAtCurrentHead() {
        let empty = entries(choices(uncommitted: 2), creating: true)
        #expect(empty.first == .header(L10n.branchFromCurrent("feat/discount")))
        #expect(items(empty).map(\.enabled) == [false])
        #expect(items(entries(choices(), query: "fix/x", creating: true)).map(\.title) == [L10n.branchCreateNamed("fix/x")])
        let note = branchSwitcherNote(choices(uncommitted: 2), loadError: nil, creating: true, progress: nil, refusal: nil)
        #expect(note?.text == L10n.branchDirtyNewHint)
        // Detached: starts from the short hash.
        #expect(entries(choices(head: .detached("abc1234")), creating: true).first == .header(L10n.branchFromCurrent("abc1234")))
        #expect(entries(choices(head: nil)).isEmpty)
    }

    @Test func refusalsMapToNotes() {
        let dirty = branchRefusalNote(BranchSwitchError.dirty(files: 3), text: "ignored")
        #expect(dirty == PopoverMenuNote(lead: L10n.branchDirty(L10n.fileCount(3)), text: L10n.branchDirtyHint, tone: .waiting))
        for e: Error in [BranchSwitchError.wouldOverwriteIgnored([".env"]), BranchSwitchError.invalidName,
                         BranchSwitchError.operationInProgress("merge"), CocoaError(.fileNoSuchFile)] {
            #expect(branchRefusalNote(e, text: "msg") == PopoverMenuNote(text: "msg", tone: .failed))
        }
    }

    /// The model on a real repo: a dirty tree refuses a switch (count, the files stay), a new branch takes the
    /// changes along and moves HEAD; an ignored `.env` the target tracks refuses with its name.
    @Test func modelSwitchesCreatesAndRefuses() async throws {
        let t = try await TempRepo.offMain { try TempRepo() }
        defer { t.cleanup() }
        try await t.git("branch", "other", in: t.repo)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: t.repo)
        let id = s.addTask(projectId: p, name: "chat")
        let dir = URL(fileURLWithPath: t.root + "/state")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        app.requestHead(app.state.tasks[0])  // the toolbar shows it
        await app.branchModel.idle()
        let m = BranchSwitcher(app: app, taskId: id)
        var toasts: [String] = []
        app.branchModel.toast = { toasts.append($0) }
        func settle() async throws {
            for _ in 0..<300 where m.progress != nil { try await Task.sleep(nanoseconds: 20_000_000) }
            await app.branchModel.idle()
        }

        try "x".write(toFile: t.repo + "/a.txt", atomically: true, encoding: .utf8)
        await m.load()
        #expect(m.choices?.uncommitted == 1)
        m.switchTo(Branch(name: "other", isRemote: false, lastCommit: .now))
        #expect(m.progress == L10n.branchSwitching("other"))
        try await settle()
        #expect(m.refusal == branchRefusalNote(BranchSwitchError.dirty(files: 1), text: ""))
        #expect(try String(contentsOfFile: t.repo + "/a.txt", encoding: .utf8) == "x")
        // It finished with no menu open: a toast, and the next open still shows the refusal; the one after doesn't.
        #expect(toasts.last == L10n.branchDirty(L10n.fileCount(1)) + " " + L10n.branchDirtyHint)
        m.opened(in: PopoverMenuPanel(content: PopoverMenuContent([])))
        #expect(m.refusal != nil)
        m.opened(in: PopoverMenuPanel(content: PopoverMenuContent([])))
        #expect(m.refusal == nil)

        m.startCreating()
        m.create("feat/new")
        try await settle()
        #expect(m.refusal == nil)
        #expect(toasts.last == L10n.branchCreated("feat/new"))
        #expect(try await t.git("branch", "--show-current", in: t.repo) == "feat/new")
        #expect(app.head(of: app.state.tasks[0]) == .branch("feat/new"))

        // Commit on `other` an `.env`, then ignore it here: switching would overwrite it.
        try await t.git("add", "a.txt", in: t.repo)
        try await t.git("commit", "-qm", "a", in: t.repo)
        try await t.git("switch", "-q", "other", in: t.repo)
        try "SECRET=1".write(toFile: t.repo + "/.env", atomically: true, encoding: .utf8)
        try await t.git("add", ".env", in: t.repo)
        try await t.git("commit", "-qm", "env", in: t.repo)
        try await t.git("switch", "-q", "feat/new", in: t.repo)
        try ".env\n".write(toFile: t.repo + "/.gitignore", atomically: true, encoding: .utf8)
        try await t.git("add", ".gitignore", in: t.repo)
        try await t.git("commit", "-qm", "ignore", in: t.repo)
        try "SECRET=mine".write(toFile: t.repo + "/.env", atomically: true, encoding: .utf8)
        await m.load()
        m.switchTo(Branch(name: "other", isRemote: false, lastCommit: .now))
        try await settle()
        #expect(m.refusal?.tone == .failed && m.refusal?.text.contains(".env") == true)
        #expect(try String(contentsOfFile: t.repo + "/.env", encoding: .utf8) == "SECRET=mine")
    }
}
