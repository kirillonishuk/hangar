import AppKit
import Foundation
import Workspace

/// Rows of the sidebar's «Чаты» beyond pinned, open and selected chats.
let freeChatsVisible = 7

/// Chats without a project: one shared folder, the default agent, asleep instead of closed.
extension AppState {
    func isFreeChatTask(_ id: UUID) -> Bool { state.freeChat(ofTask: id) != nil }

    /// A host's terminal or a chat without a project: CLI, MCP and project lists never see them.
    func isOutsideProjects(_ task: HangarTask) -> Bool {
        state.hostShells.contains { $0.id == task.projectId } || state.freeChats.contains { $0.id == task.projectId }
    }

    /// Where a chat is shown as being: its project, else «Без проекта».
    func placeName(of task: HangarTask) -> String {
        project(task.projectId)?.name ?? (state.isFreeChatTask(task) ? L10n.noProject : "")
    }

    /// The folder is Hangar's own and may have been deleted: made again, quietly.
    @discardableResult func ensureChatsFolder() -> Bool {
        guard !state.chatsFolder.isEmpty else { return false }
        return (try? FileManager.default.createDirectory(atPath: state.chatsFolder, withIntermediateDirectories: true)) != nil
    }

    /// «+» of «Чаты», ⌥⌘N: a «Чат N» with the default agent, selected; its first prompt names it (#116).
    @discardableResult func newFreeChat() -> UUID {
        ensureChatsFolder()
        let name = chatName(name: "", message: "", existing: state.freeChatTasks.map(\.name))
        var created = UUID()
        sessionsViewVisible = false
        perform { s in created = s.addFreeChat(name: name, kind: config.defaultAgent, autoNamed: true).task }
        return created
    }

    /// Its agents stop; the row stays, dimmed.
    func sleepFreeChat(_ id: UUID) { perform { $0.sleepFreeChat(taskId: id) } }

    /// A click on an asleep row: its agents resume their own conversations (#119).
    func wakeFreeChat(_ id: UUID) {
        if state.tasks.contains(where: { $0.id == id && $0.archived }) { restore(taskId: id) }
        select(taskId: id)
    }

    func removeFreeChat(_ id: UUID) { perform { $0.removeFreeChat(taskId: id) } }

    /// The sidebar's rows: pinned, open and selected chats always, the rest by last use up to `freeChatsVisible`.
    func sidebarFreeChats(limit: Int = freeChatsVisible) -> [HangarTask] {
        let all = state.freeChatTasks
        let must = Set(all.filter { $0.pinned || !$0.archived || $0.id == state.selectedTaskId }.map(\.id))
        var room = max(limit - must.count, 0)
        return all.filter { t in
            if must.contains(t.id) { return true }
            guard room > 0 else { return false }
            room -= 1
            return true
        }
    }
}

/// «сейчас», «5 мин», «3 ч», «вчера», «пн», «12 окт.», «12.10.25» — computed on each redraw, no timer.
@MainActor func freeChatTime(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
    let seconds = now.timeIntervalSince(d)
    if seconds < 60 { return L10n.freeTimeNow }
    if seconds < 3600 { return L10n.freeTimeMinutes(Int(seconds / 60)) }
    let f = DateFormatter()
    f.locale = Locale(identifier: L10n.resolve(L10n.language).rawValue)
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    switch historyDay(d, now: now, calendar: calendar) {
    case .today: return L10n.freeTimeHours(Int(seconds / 3600))
    case .yesterday: return L10n.sessionsYesterday
    case .date(let day):
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        f.setLocalizedDateFormatFromTemplate(days < 7 ? "EEE" : calendar.isDate(d, equalTo: now, toGranularity: .year) ? "dMMM" : "ddMMyy")
        return f.string(from: d)
    }
}
