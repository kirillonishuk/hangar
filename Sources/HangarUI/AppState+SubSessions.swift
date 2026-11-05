import AgentStatus
import ControlServer
import Foundation
import Workspace

/// Sub-sessions (spec `2026-11-04-sub-sessions-design.md`, #128, #131): done detection, `sessions_wait` and the user's
/// notification. Nothing is ever sent to the parent's terminal.
extension AppState {
    // MARK: Model

    /// The leaf whose agent a sub-session runs: its first claude/codex leaf.
    func agentLeaf(of task: HangarTask) -> Leaf? {
        task.tabs.flatMap(\.root.leaves).first { $0.kind == .claude || $0.kind == .codex }
    }

    func subSessionLink(_ id: UUID) -> String { LinkTarget.task(id).link.url.absoluteString }

    /// Sidebar rows of a project: its unpinned chats with their sub-chats under them (folded ones hidden).
    func groupRows(_ projectId: UUID) -> [(task: HangarTask, depth: Int)] { state.withSubSessions(groupTasks(projectId)) }

    func toggleSubsCollapsed(_ id: UUID) {
        guard let task = state.tasks.first(where: { $0.id == id }) else { return }
        perform { $0.setSubsCollapsed(taskId: id, !task.subsCollapsed) }
    }

    /// A folded parent's counter: open sub-chats (recursively) and how many of them work.
    func subChatCounts(of id: UUID) -> (total: Int, working: Int) {
        let all = state.withSubSessions([state.tasks.first { $0.id == id }].compactMap { $0 }, expandedOnly: false).dropFirst()
        return (all.count, all.filter { displayState(of: $0.task) == .working }.count)
    }

    // MARK: Creation

    /// MCP/CLI `sessions_spawn` and the «New Sub-chat» sheet: the sub-session, its agent started at once with the prompt.
    /// It works in the parent's own folder (the same worktree or main folder, #131); `worktree` — in a new worktree instead.
    func spawnSubSession(parent parentId: UUID, name: String, prompt: String, kind: LeafKind, worktree: Bool,
                         base: String?) async -> Result<UUID, ControlError> {
        guard let parent = state.tasks.first(where: { $0.id == parentId && !$0.archived }) else {
            return .failure(ControlError(code: .notFound, message: "parent is gone"))
        }
        let free = state.isFreeChatTask(parent)
        var mode: TaskMode?, setup: String?
        if worktree {
            guard !free, let project = project(parent.projectId) else {
                return .failure(ControlError(code: .badParams, message: "a chat without a project has no repository for a worktree"))
            }
            switch await countingCreation({ await worktreeMode(project, name: name, base: base) }) {
            case .success(let m): (mode, setup) = m
            case .failure(let e): return .failure(e)
            }
        }
        guard state.tasks.contains(where: { $0.id == parentId }) else { return .failure(ControlError(code: .notFound, message: "parent was removed meanwhile")) }
        if free { ensureChatsFolder() }
        var created: (task: UUID, tab: UUID)?
        var setupTab: UUID?
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { s in
            guard let c = s.addSubSession(parent: parentId, name: name, kind: kind, mode: mode),
                  let i = s.tasks.firstIndex(where: { $0.id == c.task }) else { return }
            created = c
            if let leaf = s.tasks[i].tabs.first(where: { $0.id == c.tab })?.root.leaves.first { pendingPrompts[leaf.id] = text }
            if let setup {
                let shell = s.addTab(taskId: c.task, kind: .shell)
                s.tasks[i].activeTabId = c.tab
                // Like `createTask` (#127): closes itself on success, never saved, a ⌃C still marks it failed.
                if let leaf = s.tasks[i].tabs.first(where: { $0.id == shell })?.root.leaves.first {
                    pendingPrompts[leaf.id] = setup
                    setupLeaves.insert(leaf.id)
                }
                setupTab = shell
            }
        }
        guard let created else { return .failure(ControlError(code: .failed, message: "sub-session was not created")) }
        subWatches[created.task] = SubSessionWatch(created: clock())
        terminals?.start(created.tab)
        if let setupTab { terminals?.start(setupTab) }
        if mode != nil { Task { await syncProjectStatuslines(host: project(parent.projectId)?.host) } }
        return .success(created.task)
    }

    // MARK: Done detection

    /// A sub-session's watch; one made after a restart counts as already reported (nothing is running yet, nothing to tell).
    private func watch(of task: HangarTask) -> SubSessionWatch {
        if let w = subWatches[task.id] { return w }
        var w = SubSessionWatch(created: .distantPast)
        w.started = true
        w.reported = .done
        subWatches[task.id] = w
        return w
    }

    /// A hook of `leaf` was applied: a sub-session's agent leaf updates its watch.
    func subSessionHook(leaf: UUID, kind: HookKind, background: Int?, message: String?) {
        guard let taskId = location(ofLeaf: leaf)?.task, let task = state.tasks.first(where: { $0.id == taskId }) else { return }
        if task.parentTaskId != nil, agentLeaf(of: task)?.id == leaf {
            var w = watch(of: task)
            w.hook(state: state(ofLeaf: leaf), background: background, message: message,
                   isStop: kind == .stop || kind == .codexNotify, now: clock())
            subWatches[task.id] = w
            evaluateSubSessions()
        }
    }

    /// The agent leaf's own status changed without a hook (exit, relaunch).
    func subSessionSignal(leaf: UUID) {
        guard let taskId = location(ofLeaf: leaf)?.task, subWatches[taskId] != nil else { return }
        evaluateSubSessions()
    }

    func subSessionStatus(of task: HangarTask) -> SubSessionStatus {
        guard let leaf = agentLeaf(of: task) else { return .error }
        if task.archived && !state.isFreeChatTask(task) { return .done }
        let w = watch(of: task)
        let st = state(ofLeaf: leaf.id)
        // The probe only matters once the turn is over.
        let settling = w.started && (st == .done || st == .idle)
        var detached: Int?
        // A local, live agent only: a remote project's pid is the server's (spec §9), an exited agent's pid may be reused.
        if settling, project(task.projectId)?.host == nil, terminals?.state(leaf.id) == .running,
           let pid = statuses.status(leaf.id).agentPid { detached = probeDetached(pid) }
        // The screen is read only while it can matter (it is the whole terminal's text).
        return AgentStatus.subSessionStatus(w, state: st, detached: detached, screenBusy: settling && agentScreenBusy(leaf.id), now: clock())
    }

    func agentScreenBusy(_ leaf: UUID) -> Bool { codexBusy(terminals?.read(leaf)) }

    /// Re-evaluates every watched sub-session: a newly settled one is reported once (the user's notification), waiters wake, and
    /// the next check is scheduled only while one is still settling.
    func evaluateSubSessions() {
        var next: Date?
        let now = clock()
        for (id, w) in subWatches {
            guard let task = state.tasks.first(where: { $0.id == id }) else { subWatches[id] = nil; continue }
            // Reported: nothing changes until the agent works again, and that hook resets `reported`.
            if w.reported != nil { continue }
            let status = subSessionStatus(of: task)
            if status != .running {
                if w.reported != status {
                    subWatches[id]?.reported = status
                    report(task, status: status)
                }
                continue
            }
            guard w.started, let leaf = agentLeaf(of: task), [.done, .idle].contains(state(ofLeaf: leaf.id)) else { continue }
            let poll = seconds(subPollInterval)
            // Background work: probe every `poll`; else re-check when the quiet period ends (sooner while the screen is busy).
            let at = (w.background ?? 0) > 0 ? now.addingTimeInterval(poll)
                : max(w.lastEvent.addingTimeInterval(SubSessionWatch.quiet), now.addingTimeInterval(poll / 3))
            next = min(next ?? at, at)
        }
        for c in subWaiters.values { c.resume() }
        subWaiters.removeAll()
        schedule(next)
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func schedule(_ at: Date?) {
        guard let at else { subCheck?.task.cancel(); subCheck = nil; return }
        if let current = subCheck, current.at <= at, current.at > clock() { return }
        subCheck?.task.cancel()
        let delay = max(at.timeIntervalSince(clock()), 0.05)
        subCheck = (at, Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.subCheck = nil
            self.evaluateSubSessions()
        })
    }

    /// Fully finished (#131): the user is told, as for an agent that finished out of sight; nothing reaches the parent.
    /// The banner takes the place of the leaf's own «done» one (same id). Needs-input and errors already have the leaf's
    /// own banners (permission, question, failure), with their buttons.
    private func report(_ task: HangarTask, status: SubSessionStatus) {
        guard status == .done, config.notifications, !task.muted, let leaf = agentLeaf(of: task) else { return }
        let info = subSessionInfo(task, status: status)
        onSubSessionNotice?(AgentNotice(id: leaf.id.uuidString, title: L10n.subChatDone, subtitle: task.name, body: noticeBody(info.message ?? ""),
                                        leaf: leaf.id, category: .open, thread: (task.parentTaskId ?? task.id).uuidString,
                                        sound: noticeSound(config.sounds["done"])))
    }

    /// The agent's last message, else the last lines of its screen; compact (#128): the caller's context pays for it.
    func subSessionInfo(_ task: HangarTask, status: SubSessionStatus) -> SubSessionInfo {
        let leaf = agentLeaf(of: task)
        var message = subWatches[task.id]?.lastMessage
        if message == nil, let leaf, let screen = terminals?.read(leaf.id) {
            let tail = screenTail(screen, lines: 20).text
            message = tail.isEmpty ? nil : tail
        }
        let cut = compactResult(message, max: SubSessionInfo.maxMessage)
        let agent: TabKind? = leaf.map { $0.kind == .codex ? .codex : .claude }
        let tab = leaf.flatMap { l in task.tabs.first { $0.root.leaf(id: l.id) != nil }?.id }
        var info = SubSessionInfo(id: task.id, name: task.name, status: status.rawValue, link: subSessionLink(task.id), agent: agent,
                                  message: cut.text, truncated: cut.truncated ? true : nil, tab: tab)
        info.note = task.note
        return info
    }

    // MARK: sessions_wait

    /// Returns once `waitIsOver` or at `timeout`; no polling of its own: every re-evaluation (hooks, the settle timer) wakes it,
    /// plus a check every `subPollInterval` for the probe.
    func waitForSubSessions(_ ids: [UUID], timeout: Duration) async -> [SubSessionInfo] {
        // Real time, not `clock`: the caller's MCP timeout runs on the wall clock.
        let deadline = ContinuousClock.now + timeout
        while true {
            let tasks = ids.compactMap { id in state.tasks.first { $0.id == id } }
            let statuses = tasks.map(subSessionStatus(of:))
            let now = ContinuousClock.now
            if waitIsOver(statuses) || now >= deadline || Task.isCancelled {
                return zip(tasks, statuses).map { subSessionInfo($0, status: $1) }
            }
            let nap = min(seconds(deadline - now), seconds(subPollInterval))
            let token = UUID()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                subWaiters[token] = c
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(nap))
                    self?.subWaiters.removeValue(forKey: token)?.resume()
                }
            }
        }
    }
}
