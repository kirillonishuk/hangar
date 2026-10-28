import AgentStatus
import Foundation
import Testing
import UserNotifications
import Workspace
@testable import HangarUI

/// Settings → Notifications, the project and session menu items, the muted bell.
@MainActor @Suite struct NotificationSettingsTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-notifset-\(UUID())")

    private func makeApp() throws -> (AppState, project: UUID, task: UUID) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: dir.path)
        let t = s.addTask(projectId: p, name: "a")
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        return (app, p, t)
    }

    private func configText() -> String { (try? String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)) ?? "" }

    @Test func notificationPageLabels() {
        let keys = SettingsCategory.notifications.labelKeys
        for key in [L10n.Key.notificationsTitle, .notifyPermissionTitle, .notifyQuestionTitle, .notifyFailedTitle, .notifyDoneTitle,
                    .limitNotificationsTitle, .allowFromNotificationTitle, .notifyWhenActiveTitle, .dockBadgeTitle, .sshTerminalBellTitle,
                    .keepAwakeShort, .notificationPermissionTitle] {
            #expect(keys.contains(key), "\(key)")
        }
    }

    @Test func reasonSwitchWritesConfig() throws {
        let (app, _, _) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try app.setNotify(.done, false)
        #expect(configText().contains("notify_done = false"))
        #expect(!app.config.notifyDone)
        try app.setNotify(.limit, false)
        #expect(configText().contains("limit_notifications = false"))
        #expect(!app.config.limitNotifications)
        #expect(app.notifyEnabled(.permission))
        #expect(!app.notifyEnabled(.done))
    }

    @Test func soundWritesConfig() throws {
        let (app, _, _) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try app.setSound(.permission, "")
        #expect(configText().contains("sound_permission = \"\""))
        #expect(app.config.sounds["permission"] == "")
        try app.setSound(.limit, "default")
        #expect(configText().contains("sound_limit = \"default\""))
    }

    @Test func muteActionsInMenus() throws {
        let (app, project, task) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Action.list(for: .task(task), app: app).contains(.toggleMute))
        #expect(Action.list(for: .project(project), app: app).contains(.projectNotifications))
        #expect(Action.toggleMute.title(for: .task(task), app: app) == L10n.muteSession)
        let ctx = ActionContext(app: app)
        Action.toggleMute.perform(.task(task), ctx)
        #expect(app.state.tasks.first { $0.id == task }?.muted == true)
        #expect(Action.toggleMute.title(for: .task(task), app: app) == L10n.unmuteSession)
        Action.toggleMute.perform(.task(task), ctx)
        #expect(app.state.tasks.first { $0.id == task }?.muted == false)
    }

    @Test func projectNotificationsCycles() throws {
        let (app, project, _) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = ActionContext(app: app)
        func mode() -> ProjectNotifications? { app.project(project)?.notifications }
        #expect(mode() == .all)
        Action.projectNotifications.perform(.project(project), ctx)
        #expect(mode() == .urgent)
        Action.projectNotifications.perform(.project(project), ctx)
        #expect(mode() == .off)
        Action.projectNotifications.perform(.project(project), ctx)
        #expect(mode() == .all)
        #expect(Action.projectNotifications.title(for: .project(project), app: app) == L10n.projectNotificationsItem(.all))
    }

    @Test func permissionStatusLine() {
        #expect(notificationPermission(.denied).denied)
        #expect(notificationPermission(.denied).text == L10n.notificationsDeniedInSystem)
        #expect(!notificationPermission(.authorized).denied)
        #expect(!notificationPermission(.notDetermined).denied)
    }

    @Test func systemSettingsURL() {
        #expect(notificationSettingsURL(bundleId: "app.hangar.Hangar")?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.hangar.Hangar")
    }
}
