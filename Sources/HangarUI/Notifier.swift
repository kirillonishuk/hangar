import AgentStatus
import AppKit
import Foundation
import UserNotifications
import Workspace

/// One macOS notification. `id` replaces an earlier one with the same id (a leaf's id, or `limit-<agent>`).
struct AgentNotice: Equatable {
    var id: String
    var title: String
    var subtitle: String
    var body: String
    var leaf: UUID?
}

extension AppState {
    /// Task owning the leaf and, for a tab leaf, its tab (nil for the TERMINAL panel's leaf). Archived tasks don't count.
    func owner(ofLeaf id: UUID) -> (task: HangarTask, tab: Tab?)? {
        for task in state.tasks where !task.archived {
            if task.drawer.leaf?.id == id { return (task, nil) }
            if let tab = task.tabs.first(where: { $0.root.leaf(id: id) != nil }) { return (task, tab) }
        }
        return nil
    }
}

private let noticeBodyLimit = 160

/// A transition to waiting/done in a leaf the user can't see; nil = stay quiet.
@MainActor func notice(for t: Transition, app: AppState, leafVisible: Bool) -> AgentNotice? {
    guard app.config.notifications, !leafVisible, t.to == .waiting || t.to == .done,
          let (task, tab) = app.owner(ofLeaf: t.leaf),
          let leaf = tab?.root.leaf(id: t.leaf) ?? task.drawer.leaf else { return nil }
    let agent = leaf.kind == .claude || leaf.kind == .codex ? leaf.kind.rawValue : app.title(of: leaf)
    let project = app.project(task.projectId)?.name ?? ""
    var body = app.statuses.status(t.leaf).attention?.text.flatMap { $0.isEmpty ? nil : $0 } ?? tab.map(app.tabLabel) ?? app.title(of: leaf)
    if body.count > noticeBodyLimit { body = String(body.prefix(noticeBodyLimit - 1)) + "…" }
    return AgentNotice(id: t.leaf.uuidString,
                       title: t.to == .waiting ? L10n.agentWaiting(agent) : L10n.agentDone(agent),
                       subtitle: "\(project) › \(task.name)", body: body, leaf: t.leaf)
}

/// On screen: the app is active with a key window, and the leaf is in the selected task's active tab
/// or in its expanded TERMINAL panel.
@MainActor func leafVisible(_ leaf: UUID, app: AppState, windowVisible: Bool) -> Bool {
    guard windowVisible, let task = app.selectedTask else { return false }
    if let tab = task.tabs.first(where: { $0.id == task.activeTabId }), tab.root.leaf(id: leaf) != nil { return true }
    return task.drawer.visible && task.drawer.leaf?.id == leaf
}

extension AppState {
    /// Notification click: show the leaf (select task, activate tab or expand the panel, focus it).
    /// Archived tasks are not restored.
    func reveal(leafId: UUID) {
        guard let (task, tab) = owner(ofLeaf: leafId) else { return }
        perform { s in
            s.select(taskId: task.id)
            guard let i = s.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            if let tab {
                s.tasks[i].activeTabId = tab.id
                s.setFocusedLeaf(taskId: task.id, tabId: tab.id, leafId: leafId)
            } else if !s.tasks[i].drawer.visible {
                s.toggleDrawer(taskId: task.id)
            }
        }
    }
}

/// Thin wiring over `UNUserNotificationCenter`; the decisions live in `notice(for:…)`.
@MainActor public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID) -> Void)?
    private let center: UNUserNotificationCenter

    /// nil outside an .app bundle: `UNUserNotificationCenter.current()` crashes in `swift run` and tests.
    static func makeIfAvailable() -> Notifier? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return Notifier()
    }

    private init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    /// Asks for permission on the first need; a refusal silently drops the notification.
    func post(_ n: AgentNotice) {
        Task { @MainActor in
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.subtitle = n.subtitle
            content.body = n.body
            content.sound = .default
            if let leaf = n.leaf { content.userInfo = ["leaf": leaf.uuidString] }
            do { try await center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil)) }
            catch { uiLog.error("notification failed: \(String(describing: error), privacy: .public)") }
        }
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        let leaf = (response.notification.request.content.userInfo["leaf"] as? String).flatMap(UUID.init(uuidString:))
        completionHandler()
        guard let leaf else { return }
        Task { @MainActor in self.onOpen?(leaf) }
    }
}
