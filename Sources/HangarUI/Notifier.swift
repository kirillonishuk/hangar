import AgentStatus
import AppKit
import ControlServer
import Foundation
import UserNotifications
import Workspace

/// The notification's buttons (`UNNotificationCategory` id = raw value).
enum NoticeCategory: String, CaseIterable {
    case permission, permissionAllow = "permission-allow", questionReply = "question-reply", open, limit
}

/// One macOS notification. `id` replaces an earlier one with the same id (a leaf's id, or `limit-<agent>`).
struct AgentNotice: Equatable {
    var id: String
    var title: String
    var subtitle: String
    var body: String
    var leaf: UUID?
    var category: NoticeCategory
    /// Groups a session's notifications (task id).
    var thread: String?
    /// nil — silent; otherwise the configured name (S4: played as the standard sound).
    var sound: String?
    /// Buttons act only while the leaf's attention still carries this key.
    var requestKey: UUID?
}

enum NoticeAction: Equatable, Sendable { case open, allow, reply(String), limits }

enum NoticeResult: Equatable { case reveal, send(text: String?, keys: [SendKey]), showLimits }

/// S2 (#95): the key a person presses on Claude's permission dialog ("Yes" is first).
let permissionApproveKeys: [SendKey] = [.enter]

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
private let replyLimit = 2000

private func isControl(_ c: Character) -> Bool { c.unicodeScalars.contains { $0.properties.generalCategory == .control } }

/// Control characters (escapes, newlines) become spaces; long text ends with «…».
func noticeBody(_ text: String) -> String {
    let flat = String(text.map { isControl($0) ? " " : $0 })
    return flat.count > noticeBodyLimit ? String(flat.prefix(noticeBodyLimit - 1)) + "…" : flat
}

/// `""` — no sound.
func noticeSound(_ name: String?) -> String? {
    let name = name ?? "default"
    return name.isEmpty ? nil : name
}

extension AppState {
    /// Reply types into the leaf: only codex (S5: Claude's question is an MCP form, #95); never a host terminal's shell.
    func acceptsReply(leaf id: UUID) -> Bool { leaf(id: id)?.kind == .codex }

    /// A notification button: typing happens only for the leaf's current request in a running terminal; else Open.
    func notificationAction(leaf: UUID?, requestKey: UUID?, _ action: NoticeAction) -> NoticeResult {
        func current(_ reason: AttentionReason) -> Bool {
            guard let leaf, let requestKey, let a = statuses.status(leaf).attention else { return false }
            return a.reason == reason && a.requestKey == requestKey && terminals?.state(leaf) == .running
        }
        switch action {
        case .open: return .reveal
        case .limits: return .showLimits
        case .allow:
            // Never approve blindly: the banner showed the exact command, and no newer PermissionRequest is pending.
            guard config.allowFromNotification, current(.permission), let s = leaf.map(statuses.status), let a = s.attention,
                  a.tool != nil, a.command != nil, s.pendingPermission == nil else { return .reveal }
            return .send(text: nil, keys: permissionApproveKeys)
        case .reply(let raw):
            guard let leaf, acceptsReply(leaf: leaf), current(.question) else { return .reveal }
            let text = String(raw.compactMap { $0.isNewline ? " " : isControl($0) ? nil : $0 })
                .trimmingCharacters(in: .whitespaces).prefix(replyLimit)
            return text.isEmpty ? .reveal : .send(text: String(text), keys: [.enter])
        }
    }
}

/// The banner for an attention item: title by reason, «project › session · host», body, buttons.
@MainActor func notice(for item: AttentionItem, app: AppState) -> AgentNotice {
    let a = item.attention
    let owner = app.owner(ofLeaf: item.leafId)
    let kind = app.leaf(id: item.leafId)?.kind
    let agent = kind == .claude ? "Claude" : kind == .codex ? "Codex" : item.agent
    let title = switch a.reason {
    case .permission: L10n.agentPermission(agent)
    case .question: L10n.agentQuestion(agent)
    case .done: L10n.agentDone(agent)
    case .failed: L10n.agentFailed(agent)
    case .limit: L10n.agentLimit(agent)
    }
    let session = owner?.task.name ?? ""
    var subtitle = app.project(item.projectId).map { "\($0.name) › \(session)" } ?? session
    // A host terminal is named as in the sidebar («devbox · терминал»), its session name is the host itself.
    if let host = item.host { subtitle = app.isHostShellTask(item.taskId) ? L10n.hostTerminal(host) : subtitle + " · \(host)" }
    let details = a.reason == .permission ? a.tool.flatMap { t in a.command.map { "\(t): \($0)" } } : nil
    let fallback = owner?.tab.map(app.tabLabel) ?? app.leaf(id: item.leafId).map { app.title(of: $0) } ?? ""
    let body = details ?? a.text.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    let category: NoticeCategory = switch a.reason {
    case .permission: app.config.allowFromNotification && a.tool != nil && a.command != nil ? .permissionAllow : .permission
    case .question: app.acceptsReply(leaf: item.leafId) ? .questionReply : .open
    case .done, .failed: .open
    case .limit: .limit
    }
    return AgentNotice(id: item.leafId.uuidString, title: title, subtitle: subtitle, body: noticeBody(body), leaf: item.leafId,
                       category: category, thread: item.taskId.uuidString, sound: noticeSound(app.config.sounds[a.reason.rawValue]),
                       requestKey: a.requestKey)
}

/// The banner policy plus what is on screen right now.
@MainActor func bannerAllowed(_ item: AttentionItem, app: AppState, leafVisible: Bool, appActive: Bool) -> Bool {
    var c = app.bannerContext(leafId: item.leafId, reason: item.attention.reason)
    c.leafVisible = leafVisible
    c.appActive = appActive
    return shouldBanner(item.attention.reason, c)
}

/// On screen: the app is active with a key window, and the leaf is in the selected task's active tab
/// or in its expanded TERMINAL panel.
@MainActor func leafVisible(_ leaf: UUID, app: AppState, windowVisible: Bool) -> Bool {
    guard windowVisible, let task = app.selectedTask else { return false }
    if let tab = task.tabs.first(where: { $0.id == task.activeTabId }), tab.root.leaf(id: leaf) != nil { return true }
    return task.drawer.visible && task.drawer.leaf?.id == leaf
}

extension AppState {
    /// Notification click, «Перейти» in «Сессии»: show the leaf (select task, activate tab or expand the panel, focus it).
    /// Archived tasks are not restored.
    func reveal(leafId: UUID) {
        guard let (task, tab) = owner(ofLeaf: leafId) else { return }
        // A shown diff covers the task's tabs: the revealed one must not stay behind it.
        if tab != nil, diffTabs[task.id]?.active == true { diffTabs[task.id]?.active = false }
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

/// What `Notifier` needs from the notification center: the system one, or a recorder (tests, DEBUG without a bundle).
@MainActor struct NoticeCenter {
    var authorization: () async -> UNAuthorizationStatus
    var requestAuthorization: () async -> Void
    var add: (AgentNotice) async throws -> Void
    var remove: (String) -> Void
    var removeAll: () -> Void
    var setCategories: (Set<UNNotificationCategory>) -> Void

    static func system(_ center: UNUserNotificationCenter) -> NoticeCenter {
        NoticeCenter(
            authorization: { await center.notificationSettings().authorizationStatus },
            requestAuthorization: { _ = try? await center.requestAuthorization(options: [.alert, .sound]) },
            add: { n in
                let content = UNMutableNotificationContent()
                content.title = n.title
                content.subtitle = n.subtitle
                content.body = n.body
                content.categoryIdentifier = n.category.rawValue
                content.threadIdentifier = n.thread ?? ""
                // S4 (#95): system sounds by name are unconfirmed, any chosen sound plays as the standard one.
                content.sound = n.sound == nil ? nil : .default
                // S3 (#95): .timeSensitive needs a provisioning profile the ad-hoc bundle can't have.
                content.interruptionLevel = .active
                var info: [String: String] = [:]
                if let leaf = n.leaf { info["leaf"] = leaf.uuidString }
                if let key = n.requestKey { info["requestKey"] = key.uuidString }
                content.userInfo = info
                try await center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
            },
            remove: { id in
                center.removeDeliveredNotifications(withIdentifiers: [id])
                center.removePendingNotificationRequests(withIdentifiers: [id])
            },
            removeAll: { center.removeAllDeliveredNotifications() },
            setCategories: { center.setNotificationCategories($0) })
    }

    /// Keeps what is "on screen" in `shown` (newest last); always authorized.
    static func recorder(_ shown: @escaping (([AgentNotice]) -> [AgentNotice]) -> Void) -> NoticeCenter {
        NoticeCenter(authorization: { .authorized }, requestAuthorization: {},
                     add: { n in shown { $0.filter { $0.id != n.id } + [n] } },
                     remove: { id in shown { $0.filter { $0.id != id } } },
                     removeAll: { shown { _ in [] } }, setCategories: { _ in })
    }
}

/// Thin wiring over the notification center; the decisions live in `notice(for:…)`, `bannerAllowed` and `notificationAction`.
@MainActor public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// (leaf, requestKey, action)
    var onAction: ((UUID?, UUID?, NoticeAction) -> Void)?
    private let center: NoticeCenter
    /// The post each id may still add; a remove or a newer post replaces it (posts wait for authorization first).
    private var current: [String: UUID] = [:]
    /// Tests await it.
    private(set) var lastPost: Task<Void, Never>?

    /// nil outside an .app bundle: `UNUserNotificationCenter.current()` crashes in `swift run` and tests.
    static var hasBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    static func makeIfAvailable() -> Notifier? {
        guard hasBundle else { return nil }
        let system = UNUserNotificationCenter.current()
        let notifier = Notifier(center: .system(system))
        system.delegate = notifier
        return notifier
    }

    init(center: NoticeCenter) {
        self.center = center
        super.init()
        registerCategories()
        // Last run's banners point at requests that no longer exist.
        center.removeAll()
    }

    /// Button titles follow the language: call again after a switch.
    func registerCategories() {
        let open = UNNotificationAction(identifier: "open", title: L10n.noticeOpen, options: [.foreground])
        // Typing into a terminal from the lock screen needs the user's login.
        let allow = UNNotificationAction(identifier: "allow", title: L10n.noticeAllow, options: [.authenticationRequired])
        let reply = UNTextInputNotificationAction(identifier: "reply", title: L10n.noticeReply, options: [.authenticationRequired],
                                                  textInputButtonTitle: L10n.noticeReply, textInputPlaceholder: "")
        let limits = UNNotificationAction(identifier: "limits", title: L10n.noticeOpenLimits, options: [.foreground])
        let actions: [NoticeCategory: [UNNotificationAction]] = [
            .permission: [open], .permissionAllow: [open, allow], .questionReply: [open, reply],
            .open: [open], .limit: [limits],
        ]
        center.setCategories(Set(NoticeCategory.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: actions[$0] ?? [], intentIdentifiers: [])
        }))
    }

    func authorizationStatus() async -> UNAuthorizationStatus { await center.authorization() }

    /// Banners for attention out of sight; withdrawn when the attention goes, a newer request stays quiet, or the leaf is seen.
    func attach(to app: AppState, leafVisible: @escaping (UUID) -> Bool, appActive: @escaping () -> Bool) {
        // onAttention fires only on a change, and the same request keeps its whole Attention: non-nil = a new requestKey.
        app.onAttention = { [weak self, weak app] leaf, attention in
            guard let self, let app else { return }
            guard attention != nil, let item = app.attentionItems.first(where: { $0.leafId == leaf }),
                  bannerAllowed(item, app: app, leafVisible: leafVisible(leaf), appActive: appActive())
            else { self.remove(leaf: leaf); return }  // a newer request not to be shown makes the old banner stale too
            self.post(notice(for: item, app: app))
        }
        app.onLeafSeen = { [weak self] in self?.remove(leaf: $0) }
        // Only withdraws: a banner the old policy held back is not posted late.
        app.onBannerPolicy = { [weak self, weak app] in
            guard let self, let app else { return }
            for item in app.attentionItems
            where !shouldBanner(item.attention.reason, app.bannerContext(leafId: item.leafId, reason: item.attention.reason)) {
                self.remove(leaf: item.leafId)
            }
        }
    }

    /// Asks for permission on the first need; a refusal silently drops the notification.
    @discardableResult func post(_ n: AgentNotice) -> Task<Void, Never> {
        let token = UUID()
        current[n.id] = token
        let task = Task { @MainActor in
            var status = await center.authorization()
            if status == .notDetermined {
                await center.requestAuthorization()
                status = await center.authorization()
            }
            guard status == .authorized || status == .provisional, current[n.id] == token else { return }
            do { try await center.add(n) }
            catch { uiLog.error("notification failed: \(String(describing: error), privacy: .public)") }
            // Withdrawn while it was being added.
            if current[n.id] == nil { center.remove(n.id) }
        }
        lastPost = task
        return task
    }

    /// The leaf's attention is gone or seen: its banner goes from the Notification Center (and a pending post is dropped).
    func remove(leaf: UUID) {
        current[leaf.uuidString] = nil
        center.remove(leaf.uuidString)
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let content = response.notification.request.content
        let leaf = (content.userInfo["leaf"] as? String).flatMap(UUID.init(uuidString:))
        let key = (content.userInfo["requestKey"] as? String).flatMap(UUID.init(uuidString:))
        let action: NoticeAction? = switch response.actionIdentifier {
        // A click on a limit banner opens the limits, as its only button does.
        case UNNotificationDefaultActionIdentifier: content.categoryIdentifier == NoticeCategory.limit.rawValue ? .limits : .open
        case "open": .open
        case "allow": .allow
        case "reply": .reply((response as? UNTextInputNotificationResponse)?.userText ?? "")
        case "limits": .limits
        default: nil  // dismissed
        }
        guard let action else { return completionHandler() }
        // The system may suspend us once the handler runs: finish the action (typing included) first.
        Task { @MainActor in
            self.onAction?(leaf, key, action)
            completionHandler()
        }
    }
}
