import AgentStatus
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

    func clearDone() {
        for (id, s) in statuses.leaves where s.attention?.reason == .done { dismissDone(leafId: id) }
    }

    func setProjectNotifications(_ id: UUID, _ value: ProjectNotifications) {
        perform { $0.setProjectNotifications(projectId: id, value) }
    }

    func setMuted(taskId: UUID, _ muted: Bool) { perform { $0.setMuted(taskId: taskId, muted) } }

    /// ⌥⌘A: the next leaf in inbox order after the selected task's focused leaf.
    func nextAttentionLeaf() -> UUID? {
        let (urgent, done) = inboxSections(attentionItems)
        let current = selectedTask.flatMap { t in t.tabs.first { $0.id == t.activeTabId }?.focusedLeafId }
        return nextAttention((urgent + done).map(\.leafId), after: current)
    }

    /// Banner policy for the leaf without the on-screen conditions (the caller adds those).
    func bannerContext(leafId: UUID, reason: AttentionReason) -> BannerContext {
        let task = owner(ofLeaf: leafId)?.task
        let mode = task.flatMap { project($0.projectId) }?.notifications ?? .all
        let reasonEnabled = switch reason {
        case .permission: config.notifyPermission
        case .question: config.notifyQuestion
        case .done: config.notifyDone
        case .failed: config.notifyFailed
        case .limit: config.limitNotifications
        }
        return BannerContext(enabled: config.notifications, reasonEnabled: reasonEnabled, projectUrgentOnly: mode == .urgent,
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
