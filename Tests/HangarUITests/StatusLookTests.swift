import AgentStatus
import AppKit
import ControlServer
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// HD-135: seen / unseen «готово», the waiting time, status marks without colour, the split pane frame, diff tints.
@MainActor @Suite(.serialized) struct StatusLookTests {
    struct Fixture {
        var app: AppState
        var task: UUID
        var other: UUID
        /// claude, codex (task), claude (other)
        var leaves: [Leaf]
        var tabs: [UUID]
    }

    private func make() -> Fixture {
        var s = WorkspaceState()
        let p = s.addProject(name: "shop-api", path: "/tmp")
        let t = s.addTask(projectId: p, name: "fix-auth")
        s.addTab(taskId: t, kind: .claude)
        s.addTab(taskId: t, kind: .codex)
        let o = s.addTask(projectId: p, name: "other")
        s.addTab(taskId: o, kind: .claude)
        s.select(taskId: o)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-look-\(UUID())")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(),
                           configURL: dir.appendingPathComponent("c.toml"), socketPath: "/tmp/hg-test/hangar.sock")
        app.keepAwake = .inert()
        app.codexRead = nil
        app.clock = { Date(timeIntervalSince1970: 1_000_000) }
        let tabs = [t, o].flatMap { id in app.state.tasks.first { $0.id == id }!.tabs }
        return Fixture(app: app, task: t, other: o, leaves: tabs.map { $0.root.leaves[0] }, tabs: tabs.map(\.id))
    }

    private func event(_ f: Fixture, _ n: Int, _ kind: HookKind, type: String? = nil, message: String? = nil) {
        f.app.handle(.event(EventMessage(tab: f.tabs[n], leaf: f.leaves[n].id, kind: kind, notificationType: type, message: message)))
    }

    private func task(_ f: Fixture, _ id: UUID) -> HangarTask { f.app.state.tasks.first { $0.id == id }! }

    /// A done out of sight stays new; selecting the chat shows its active tab (seen), another tab stays new until shown.
    @Test func doneIsSeenWhenShown() {
        let f = make()
        var shown = true
        f.app.screenShown = { shown }
        event(f, 0, .stop)
        event(f, 1, .stop)
        #expect(!f.app.doneSeen(task(f, f.task)))
        #expect(f.app.attentionItems.filter { $0.attention.reason == .done }.count == 2)
        f.app.select(taskId: f.task)  // its active tab: the codex one (added last)
        #expect(f.app.statuses.status(f.leaves[0].id).unseen && !f.app.statuses.status(f.leaves[1].id).unseen)
        #expect(f.app.attentionItems.map(\.leafId) == [f.leaves[0].id])  // a seen done leaves «Готово недавно»
        #expect(!f.app.canMarkUnread(f.task))
        f.app.activate(tabId: f.tabs[0])
        #expect(f.app.doneSeen(task(f, f.task)) && f.app.canMarkUnread(f.task))
        // Hidden window: a done in view isn't seen; shown again, it is.
        shown = false
        f.app.refreshSeen()
        event(f, 0, .prompt)
        event(f, 0, .stop)
        #expect(f.app.statuses.status(f.leaves[0].id).unseen)
        shown = true
        f.app.refreshSeen()
        #expect(!f.app.statuses.status(f.leaves[0].id).unseen)
        // On screen when it finishes: seen at once.
        event(f, 0, .prompt)
        event(f, 0, .stop)
        #expect(!f.app.statuses.status(f.leaves[0].id).unseen)
    }

    /// «Отметить непрочитанным» on the chat in view holds until it's left and shown again.
    @Test func markUnreadHoldsWhileInView() {
        let f = make()
        f.app.screenShown = { true }
        f.app.select(taskId: f.task)
        f.app.activate(tabId: f.tabs[0])
        event(f, 0, .stop)
        #expect(f.app.doneSeen(task(f, f.task)))
        Action.markUnread.perform(.task(f.task), ActionContext(app: f.app))
        #expect(!f.app.doneSeen(task(f, f.task)) && !f.app.canMarkUnread(f.task))
        #expect(f.app.attentionItems.contains { $0.leafId == f.leaves[0].id && $0.attention.reason == .done })
        f.app.refreshSeen()
        #expect(!f.app.doneSeen(task(f, f.task)))
        f.app.select(taskId: f.other)
        f.app.select(taskId: f.task)
        #expect(f.app.doneSeen(task(f, f.task)))
        #expect(Action.list(for: .task(f.task), app: f.app).first == .markUnread)
        #expect(!Action.list(for: .task(f.other), app: f.app).contains(.markUnread))
    }

    /// The row's word and tooltip: how long, who, what (the oldest request of the chat).
    @Test func waitingWordAndTooltip() {
        defer { L10n.language = .system }
        L10n.language = .ru
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(rowWaitingWord(since: nil, now: now) == "ждёт")
        #expect(rowWaitingWord(since: now.addingTimeInterval(-299), now: now) == "ждёт")
        #expect(rowWaitingWord(since: now.addingTimeInterval(-300), now: now) == "ждёт 5 м")
        #expect(rowWaitingWord(since: now.addingTimeInterval(-59 * 60), now: now) == "ждёт 59 м")
        #expect(rowWaitingWord(since: now.addingTimeInterval(-7300), now: now) == "ждёт 2 ч")
        L10n.language = .en
        #expect(rowWaitingWord(since: now.addingTimeInterval(-720), now: now) == "waiting 12m")
        L10n.language = .ru

        let f = make()
        event(f, 1, .notification, message: "Would you like to run pnpm vitest?")
        let since = f.app.clock()
        let status = f.app.sessionStatus(of: task(f, f.task), now: since.addingTimeInterval(4 * 60 + 10))
        #expect(status.text == "ждёт 4 мин · codex · Would you like to run pnpm vitest?" && status.tone == .waiting)
        #expect(f.app.rowAccessibility("fix-auth", task: task(f, f.task), state: .waiting, now: since.addingTimeInterval(60))
                == "fix-auth, ждёт ответа 1 мин")
        event(f, 2, .stop)
        #expect(f.app.rowAccessibility("other", task: task(f, f.other), state: .done, now: since) == "other, готово, не просмотрено")
    }

    /// Minute ticks only while a row waits; otherwise one entry and nothing after it.
    @Test func minuteTicksOnlyWhileWaiting() {
        let start = Date(timeIntervalSinceReferenceDate: 600 + 15)
        var idle = MinutesWhile(active: false).entries(from: start, mode: .normal)
        #expect(idle.next() == start && idle.next() == nil)
        var waiting = MinutesWhile(active: true).entries(from: start, mode: .normal)
        #expect(waiting.next() == start)
        #expect(waiting.next() == Date(timeIntervalSinceReferenceDate: 660))
        #expect(waiting.next() == Date(timeIntervalSinceReferenceDate: 720))
    }

    /// Status icons (HD-144): every state but idle has its own shape; only a seen done is dimmed.
    @Test func statusIconsDifferByShape() {
        #expect(StatusMark.icon(.working) == .spinner)
        #expect(StatusMark.icon(.done) == .check)
        #expect(StatusMark.icon(.waiting) == .questionMark)
        #expect(StatusMark.icon(.failed) == .exclamation)
        #expect(StatusMark.icon(.limit) == .hourglass)
        #expect(StatusMark.icon(.idle) == nil)
        let icons = AgentState.allCases.compactMap(StatusMark.icon)
        #expect(Set(icons).count == AgentState.allCases.count - 1)
        #expect(StatusMark.dimmed(.done, seen: true) && !StatusMark.dimmed(.done, seen: false))
        #expect(AgentState.allCases.filter { $0 != .done }.allSatisfy { !StatusMark.dimmed($0, seen: true) })
    }

    /// The spinner turns only while working, on screen and without Reduce Motion (HD-144: zero work at idle).
    @Test func spinnerTurnsOnlyWhenSeen() {
        #expect(StatusMark.spins(.working, reducedMotion: false, windowVisible: true))
        #expect(!StatusMark.spins(.working, reducedMotion: true, windowVisible: true))
        #expect(!StatusMark.spins(.working, reducedMotion: false, windowVisible: false))
        for state in AgentState.allCases where state != .working {
            #expect(!StatusMark.spins(state, reducedMotion: false, windowVisible: true))
        }
    }

    /// The system's Increase Contrast strengthens meta text and separators and redraws like a theme switch.
    @Test func accessibilityOptionsApply() {
        defer { Theme.applyAccessibility(increaseContrast: false) }
        let base = ThemePalette.of(Theme.current)
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .hangarThemeDidChange, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        Theme.applyAccessibility(increaseContrast: true)
        #expect(Theme.palette.text3 == base.text2 && Theme.palette.line == base.line2 && Theme.palette.text1 == base.text1)
        #expect(posted == 1)
        Theme.applyAccessibility(increaseContrast: true)
        #expect(posted == 1)  // no change, no redraw
        Theme.applyAccessibility(increaseContrast: false)
        #expect(Theme.palette.text3 == base.text3 && Theme.palette.line == base.line && posted == 2)
    }

    /// Only a waiting or failed pane of a split tab gets the frame.
    @Test func paneFrameOnlyInSplits() {
        #expect(paneFrame(.waiting, split: true) == .waiting)
        #expect(paneFrame(.failed, split: true) == .failed)
        #expect(paneFrame(.waiting, split: false) == nil)
        for state in [AgentState.working, .done, .idle, .limit] { #expect(paneFrame(state, split: true) == nil) }
    }

    /// Diff rows: a pale tint (≤ .10), the changed characters a visible step over it, code still readable on both.
    @Test(arguments: AppTheme.allCases) func diffTintsReadable(_ theme: AppTheme) {
        let p = ThemePalette.of(theme)
        func over(_ top: Hex, _ bottom: UInt32) -> UInt32 {
            func ch(_ shift: UInt32) -> UInt32 {
                let t = Double((top.rgb >> shift) & 0xff), b = Double((bottom >> shift) & 0xff)
                return UInt32((t * top.alpha + b * (1 - top.alpha)).rounded()) << shift
            }
            return ch(16) | ch(8) | ch(0)
        }
        for (row, git) in [(p.diffAdd, p.gitA), (p.diffDel, p.gitD)] {
            #expect(row.alpha <= 0.10, "\(theme.rawValue) row tint")
            let line = over(row, p.bg0.rgb)
            let chars = over(Hex(git.rgb, Theme.Diff.changedChars), line)
            #expect(contrastRatio(line, chars) >= 1.4, "\(theme.rawValue) changed chars stand out")
            #expect(contrastRatio(p.text1.rgb, chars) >= 4.5, "\(theme.rawValue) text on changed chars")
        }
    }
}
