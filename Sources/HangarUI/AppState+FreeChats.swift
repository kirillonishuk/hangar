import AgentStatus
import AppKit
import Foundation
import History
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

    /// History's «Продолжить» on a conversation of the folder no chat holds: a new chat resuming it.
    func openFreeChat(resuming c: Conversation) {
        guard let id = validSessionId(c.id) else { beep(); return }
        ensureChatsFolder()
        sessionsViewVisible = false
        deactivateDiff()
        perform { s in
            let task = s.addFreeChatTask(name: sessionName(c.title), autoNamed: false)
            // Marked inside `perform`: the tab's first launch must already resume.
            if let leaf = s.addResumeTab(taskId: task, kind: c.agent == .claude ? .claude : .codex, cwd: s.chatsFolder, sessionId: id) {
                restoredLeaves.insert(leaf)
            }
        }
    }

    /// The chats folder's conversations (History «Чаты»), read like a project's.
    func chatConversations() async -> [Conversation] {
        guard folderExists(state.chatsFolder) else { return [] }
        return await history.local(folder: state.chatsFolder, claudeDir: claudeSettingsURL.deletingLastPathComponent(),
                                   codexDir: codexConfigURL.deletingLastPathComponent(), open: openConversationIds)
    }

    /// Files dropped on «Файлы» of a chat without a project: copied (never moved) into the folder, then a mention of each
    /// is typed into the active tab's agent without Enter, to ask about them (`freeChatMention`). Returns the names as copied.
    @discardableResult func dropIntoChats(_ urls: [URL]) -> [String] {
        guard let task = selectedTask, state.isFreeChatTask(task), ensureChatsFolder() else { return [] }
        let fm = FileManager.default
        var names: [String] = []
        for url in urls where url.isFileURL {
            // `"` can't be mentioned inside a quoted name by either agent: it becomes `'`. A dangling symlink is taken too.
            let base = url.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
            let name = freeChatCopyName(base) { (try? fm.attributesOfItem(atPath: state.chatsFolder + "/" + $0)) != nil }
            do {
                try fm.copyItem(at: url, to: URL(fileURLWithPath: state.chatsFolder + "/" + name))
                names.append(name)
            } catch {
                uiLog.error("drop into chats failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !names.isEmpty, let tab = task.tabs.first(where: { $0.id == task.activeTabId }), let leaf = tab.root.leaf(id: tab.focusedLeafId),
           leaf.kind == .claude || leaf.kind == .codex, terminals?.state(leaf.id) == .running {
            terminals?.send(leaf.id, names.map { freeChatMention($0, agent: leaf.kind) + " " }.joined(), [])
        }
        return names
    }

    /// History «Чаты»: conversations of the folder whose text holds `query`.
    func matchChatText(_ query: String) async -> Set<String> {
        await history.matching(query, folder: state.chatsFolder, claudeDir: claudeSettingsURL.deletingLastPathComponent(),
                               codexDir: codexConfigURL.deletingLastPathComponent())
    }

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

/// A file in the chats folder as the agent's composer writes it: Claude `@name` or `@"name with spaces"` (its prompt
/// parser takes both); Codex inserts the bare path, in quotes when it has whitespace (its `@` popup does the same).
func freeChatMention(_ name: String, agent: LeafKind) -> String {
    let quoted = name.contains(where: \.isWhitespace) ? "\"" + name + "\"" : name
    return agent == .codex ? quoted : "@" + quoted
}

/// One formatter for the rows' dates; its locale, calendar and zone follow each call.
@MainActor private let freeChatDateFormatter = DateFormatter()

/// «сейчас», «5 мин», «3 ч», «вчера», «пн», «12 окт.», «12.10.25» — computed on each redraw, no timer.
@MainActor func freeChatTime(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
    let seconds = now.timeIntervalSince(d)
    if seconds < 60 { return L10n.freeTimeNow }
    if seconds < 3600 { return L10n.freeTimeMinutes(Int(seconds / 60)) }
    let f = freeChatDateFormatter
    let locale = Locale(identifier: L10n.resolve(L10n.language).rawValue)
    if f.locale != locale { f.locale = locale }
    if f.calendar != calendar { f.calendar = calendar }
    if f.timeZone != calendar.timeZone { f.timeZone = calendar.timeZone }
    switch historyDay(d, now: now, calendar: calendar) {
    case .today: return L10n.freeTimeHours(Int(seconds / 3600))
    case .yesterday: return L10n.sessionsYesterday
    case .date(let day):
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        f.setLocalizedDateFormatFromTemplate(days < 7 ? "EEE" : calendar.isDate(d, equalTo: now, toGranularity: .year) ? "dMMM" : "ddMMyy")
        return f.string(from: d)
    }
}

/// A free name in the folder: «report.pdf», then «report 2.pdf», «report 3.pdf»…
func freeChatCopyName(_ name: String, taken: (String) -> Bool) -> String {
    guard taken(name) else { return name }
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
        if !taken(candidate) { return candidate }
        n += 1
    }
}
