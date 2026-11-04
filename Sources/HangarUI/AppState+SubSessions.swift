import AgentStatus
import AppKit
import ControlServer
import Foundation
import Workspace

/// Sub-sessions (spec `2026-11-04-sub-sessions-design.md`, #128): done detection, `sessions_wait` and the parent's notes.
extension AppState {
    // MARK: Model

    /// The leaf whose agent a sub-session runs: its first claude/codex leaf.
    func agentLeaf(of task: HangarTask) -> Leaf? {
        task.tabs.flatMap(\.root.leaves).first { $0.kind == .claude || $0.kind == .codex }
    }

    /// Where a parent's notes are typed: the active tab's focused leaf when it runs an agent, else its first agent leaf.
    func parentAgentLeaf(of task: HangarTask) -> Leaf? {
        if let tab = task.tabs.first(where: { $0.id == task.activeTabId }), let leaf = tab.root.leaf(id: tab.focusedLeafId),
           leaf.kind == .claude || leaf.kind == .codex { return leaf }
        return agentLeaf(of: task)
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

    /// Appended to every sub-session's prompt: its last message is all its parent gets (#128).
    static let subSessionPromptSuffix = "\n\n(You run as a Hangar sub-session. When you are done, end with a concise final result: "
        + "what you found or did, key paths and links, under 1500 characters. Only that last message goes back to the chat that started you.)"

    /// MCP/CLI `sessions_spawn` and the «New Sub-chat» sheet: the sub-session, its agent started at once with the prompt.
    func spawnSubSession(parent parentId: UUID, name: String, prompt: String, kind: LeafKind, worktree: Bool, base: String?,
                         delivery: SubDelivery) async -> Result<UUID, ControlError> {
        guard let parent = state.tasks.first(where: { $0.id == parentId && !$0.archived }) else {
            return .failure(ControlError(code: .notFound, message: "parent is gone"))
        }
        let free = state.isFreeChatTask(parent)
        var mode = TaskMode.mainFolder, setup: String?
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
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines) + Self.subSessionPromptSuffix
        perform { s in
            guard let c = s.addSubSession(parent: parentId, name: name, kind: kind, mode: mode, delivery: delivery),
                  let i = s.tasks.firstIndex(where: { $0.id == c.task }) else { return }
            created = c
            if let leaf = s.tasks[i].tabs.first(where: { $0.id == c.tab })?.root.leaves.first { pendingPrompts[leaf.id] = text }
            if let setup {
                let shell = s.addTab(taskId: c.task, kind: .shell)
                s.tasks[i].activeTabId = c.tab
                if let leaf = s.tasks[i].tabs.first(where: { $0.id == shell })?.root.leaves.first { pendingPrompts[leaf.id] = setup }
                setupTab = shell
            }
        }
        guard let created else { return .failure(ControlError(code: .failed, message: "sub-session was not created")) }
        subWatches[created.task] = SubSessionWatch(created: clock())
        terminals?.start(created.tab)
        if let setupTab { terminals?.start(setupTab) }
        if mode != .mainFolder { Task { await syncProjectStatuslines(host: project(parent.projectId)?.host) } }
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

    /// A hook of `leaf` was applied: a sub-session's agent leaf updates its watch; a parent's leaf may take its notes now.
    func subSessionHook(leaf: UUID, kind: HookKind, background: Int?, message: String?) {
        guard let taskId = location(ofLeaf: leaf)?.task, let task = state.tasks.first(where: { $0.id == taskId }) else { return }
        if task.parentTaskId != nil, agentLeaf(of: task)?.id == leaf {
            var w = watch(of: task)
            w.hook(state: state(ofLeaf: leaf), background: background, message: message,
                   isStop: kind == .stop || kind == .codexNotify, now: clock())
            subWatches[task.id] = w
            evaluateSubSessions()
        }
        if parentNotes[taskId]?.isEmpty == false { deliverNotes(to: taskId) }
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

    /// Re-evaluates every watched sub-session: a newly settled one is reported once (its parent's note), waiters wake, and
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

    private func report(_ task: HangarTask, status: SubSessionStatus) {
        let info = subSessionInfo(task, status: status)
        if task.subDelivery == .notify {
            // Nothing for the parent's context: the user is told, as for an agent that finished out of sight.
            if config.notifications, !task.muted {
                onSubSessionNotice?(AgentNotice(id: "sub-" + task.id.uuidString, title: L10n.subChatResult(status), subtitle: task.name,
                                                body: noticeBody(info.message ?? ""), leaf: agentLeaf(of: task)?.id, category: .open,
                                                thread: (task.parentTaskId ?? task.id).uuidString, sound: noticeSound(config.sounds["done"])))
            }
            return
        }
        guard let parent = task.parentTaskId, state.tasks.contains(where: { $0.id == parent }) else { return }
        parentNotes[parent, default: []].removeAll { $0.task == task.id }
        parentNotes[parent, default: []].append(SubSessionNote(task: task.id, name: task.name, status: status, message: info.message, link: info.link))
        deliverNotes(to: parent)
    }

    /// The agent's last message, else the last lines of its screen; compact (#128): the parent's context pays for it.
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
        return SubSessionInfo(id: task.id, name: task.name, status: status.rawValue, link: subSessionLink(task.id), agent: agent,
                              message: cut.text, truncated: cut.truncated ? true : nil, tab: tab)
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

    // MARK: Parent notes

    /// Types the parent's queued notes into its agent leaf when that is idle and the user is not typing (§7b); else retries.
    func deliverNotes(to parent: UUID) {
        guard let notes = parentNotes[parent], !notes.isEmpty else { return }
        guard let task = state.tasks.first(where: { $0.id == parent }) else { parentNotes[parent] = nil; return }
        // Asleep / archived: its agent's next hook after waking brings the notes.
        guard !task.archived, let leaf = parentAgentLeaf(of: task) else { return }
        let input = ParentInput(running: terminals?.state(leaf.id) == .running, state: state(ofLeaf: leaf.id),
                                screenBusy: agentScreenBusy(leaf.id), draft: leafDrafts[leaf.id] ?? false, lastKey: leafLastKey[leaf.id])
        guard input.canDeliver(now: clock()) else { retryNotesLater(); return }
        parentNotes[parent] = nil
        terminals?.send(leaf.id, notes.map(\.line).joined(separator: "\n"), [.enter])
    }

    private func retryNotesLater() {
        guard noteRetry == nil else { return }
        let interval = noteRetryInterval
        noteRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self else { return }
            self.noteRetry = nil
            for parent in Array(self.parentNotes.keys) where self.state.tasks.contains(where: { $0.id == parent && !$0.archived }) {
                self.deliverNotes(to: parent)
            }
        }
    }

    /// A key went on to a terminal leaf (key monitor): drafts and the typing pause for notes.
    func keyTyped(leaf: UUID, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        let scalar = characters?.unicodeScalars.first
        let printable = scalar.map { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) } ?? false
        let before = leafDrafts[leaf] ?? false
        let after = draftAfterKey(before, keyCode: keyCode, control: modifiers.contains(.control), command: modifiers.contains(.command),
                                  printable: printable)
        if after != before { leafDrafts[leaf] = after ? true : nil }
        leafLastKey[leaf] = clock()
        if before && !after, !parentNotes.isEmpty { retryNotesLater() }
    }
}
