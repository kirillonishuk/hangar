import AgentStatus
import ControlServer
import Foundation
import Workspace

/// One attention list (live leaves of unarchived tasks) feeds the Dock badge, the inbox and notifications.
extension AppState {
    var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        for task in state.tasks where !task.archived {
            for leaf in task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap({ $0 }) {
                guard let a = statuses.status(leaf.id).attention else { continue }
                let agent = leaf.kind == .claude || leaf.kind == .codex ? leaf.kind.rawValue : title(of: leaf)
                items.append(AttentionItem(leafId: leaf.id, taskId: task.id, projectId: task.projectId,
                                           host: remoteLeafHost(leaf.id) ?? hostShellHost(ofLeaf: leaf.id), agent: agent, attention: a))
            }
        }
        return sortedAttention(items)
    }

    /// «Убрать»: only a done record goes; the tab keeps its done dot.
    func dismissDone(leafId: UUID) {
        guard statuses.status(leafId).attention?.reason == .done else { return }
        _ = statuses.dismissDone(leafId)
        onAttention?(leafId, nil)
    }

    /// A banner's or inbox row's answer typed into the leaf: that request is handled, its row and banner go,
    /// and a second press finds no current request (only opens).
    func sendAnswer(leafId: UUID, requestKey: UUID?, text: String?, keys: [SendKey]) {
        terminals?.send(leafId, text, keys)
        guard let requestKey, statuses.clearAnswered(leafId, requestKey: requestKey) else { return }
        onAttention?(leafId, nil)
    }

    func clearDone() {
        for (id, s) in statuses.leaves where s.attention?.reason == .done { dismissDone(leafId: id) }
    }

    func setProjectNotifications(_ id: UUID, _ value: ProjectNotifications) {
        perform { $0.setProjectNotifications(projectId: id, value) }
    }

    func setMuted(taskId: UUID, _ muted: Bool) { perform { $0.setMuted(taskId: taskId, muted) } }

    func notifyEnabled(_ reason: AttentionReason) -> Bool {
        switch reason {
        case .permission: config.notifyPermission
        case .question: config.notifyQuestion
        case .done: config.notifyDone
        case .failed: config.notifyFailed
        case .limit: config.limitNotifications
        }
    }

    /// The reason's switch on the notifications page (limit keeps its older key).
    func setNotify(_ reason: AttentionReason, _ on: Bool) throws {
        switch reason {
        case .permission: try setConfig("notify_permission", flag: on) { $0.notifyPermission = on }
        case .question: try setConfig("notify_question", flag: on) { $0.notifyQuestion = on }
        case .done: try setConfig("notify_done", flag: on) { $0.notifyDone = on }
        case .failed: try setConfig("notify_failed", flag: on) { $0.notifyFailed = on }
        case .limit: try setConfig("limit_notifications", flag: on) { $0.limitNotifications = on }
        }
    }

    /// `""` = silent, `"default"` = standard (S4: no named system sounds).
    func setSound(_ reason: AttentionReason, _ value: String) throws {
        try setConfig("sound_\(reason.rawValue)", value) { $0.sounds[reason.rawValue] = value }
    }

    /// ⌥⌘A: the next leaf in inbox order after the focused one (the TERMINAL panel's when it has focus, else the active tab's).
    func nextAttentionLeaf(drawerFocused: UUID? = nil) -> UUID? {
        let (urgent, done) = inboxSections(attentionItems)
        let current = drawerFocused ?? selectedTask.flatMap { t in t.tabs.first { $0.id == t.activeTabId }?.focusedLeafId }
        return nextAttention((urgent + done).map(\.leafId), after: current)
    }

    /// The bell / «ждут» click: opens even when empty («Никто не ждёт» is the answer).
    func toggleInbox() {
        if inboxShown { setInboxShown(false); return }
        inboxClock = clock()
        inboxShown = true
    }

    /// Popover binding: a transient close (outside click) is remembered for `inboxClicked`.
    func setInboxShown(_ shown: Bool) {
        if inboxShown, !shown { inboxClosedAt = uptime() }
        inboxShown = shown
    }

    /// As `limitsClicked`: NSPopover closes on mouse-down, the button fires on mouse-up — that click must not reopen it.
    func inboxClicked() {
        if !inboxShown, let closed = inboxClosedAt, uptime() - closed < 0.3 { return }
        toggleInbox()
    }

    /// Banner policy for the leaf without the on-screen conditions (the caller adds those).
    func bannerContext(leafId: UUID, reason: AttentionReason) -> BannerContext {
        let task = owner(ofLeaf: leafId)?.task
        let mode = task.flatMap { project($0.projectId) }?.notifications ?? .all
        return BannerContext(enabled: config.notifications, reasonEnabled: notifyEnabled(reason), projectUrgentOnly: mode == .urgent,
                             projectOff: mode == .off, sessionMuted: task?.muted ?? false, notifyWhenActive: config.notifyWhenActive)
    }

    /// A leaf's attention changed: tell the listeners; a new permission or question bounces the Dock unless silenced.
    func attentionChanged(_ leafId: UUID, from old: Attention?, to new: Attention?) {
        guard new != old else { return }
        onAttention?(leafId, new)
        guard let new, new.requestKey != old?.requestKey, new.reason == .permission || new.reason == .question,
              config.dockBadge, shouldBanner(new.reason, bannerContext(leafId: leafId, reason: new.reason)) else { return }
        requestAttention?()
    }
}
