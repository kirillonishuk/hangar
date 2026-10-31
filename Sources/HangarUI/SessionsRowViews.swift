import AgentStatus
import History
import SwiftUI
import Workspace

/// A group heading, 28 (§3.17): chevron, project `caption` 600 `text3`, host only for the scope «Все», row count right.
/// A click folds it.
struct SessionsGroupHeader: View {
    let group: SessionsGroup
    let showHost: Bool
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.historyRowGap) {
                // In the rows' icon column: the name lines up with the titles.
                IconView(icon: collapsed ? .chevronRight : .chevronDown, size: Theme.Icon.inline, tint: Theme.ui.text3)
                    .frame(width: Theme.Icon.toolbar)
                Text(verbatim: group.name).font(Theme.Typography.caption.font(.semibold)).lineLimit(1)
                if showHost, let host = group.host {
                    HStack(spacing: Theme.Space.s1) {
                        IconView(icon: .sshHost, size: Theme.Icon.inline, tint: Theme.ui.text3)
                        Text(verbatim: host).font(Theme.Typography.caption.font()).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !group.items.isEmpty {
                    Text(verbatim: "\(group.items.count)").font(Theme.Typography.caption.font())
                }
            }
            .foregroundStyle(Theme.ui.text3)
            .padding(.leading, Theme.historyRowInset + Theme.historyRowPaddingH)
            .padding(.trailing, Theme.historyRowInset + Theme.historyRowPaddingH)
            .frame(height: Theme.historyGroupHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}

/// A row: agent (or terminal) icon · title · where (folder / ⎇ and branch, mono) · state word · time. Under the pointer
/// the state and time give way to the actions (regular small buttons, the trash beside «Восстановить»); nothing moves.
struct SessionsRow: View {
    let app: AppState
    let model: SessionsModel
    let item: SessionsItem
    let ctx: ActionContext
    let run: (SessionsAction) -> Void

    var body: some View {
        let hovered = model.hovered == item.id
        let selected = model.selection == item.id
        // The keyboard's row shows its actions too: ↩'s target is visible. State and time keep their place, hidden.
        let active = hovered || selected
        HStack(spacing: Theme.historyRowGap) {
            icon
            Text(verbatim: title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            place.frame(width: Theme.historyWhereWidth, alignment: .leading)
            state.frame(width: Theme.historyStateWidth, alignment: .leading).opacity(active ? 0 : 1)
            Text(verbatim: time)
                .font(Theme.Typography.monoSmall.font()).foregroundStyle(Theme.ui.text3).lineLimit(1)
                .frame(width: Theme.historyTimeWidth, alignment: .trailing)
                .opacity(active ? 0 : 1)
        }
        .font(Theme.Typography.body.font())
        .foregroundStyle(Theme.ui.text1)
        .padding(.horizontal, Theme.historyRowPaddingH)
        .frame(height: Theme.historyRowHeight)
        .background(selected ? Theme.ui.selected : hovered ? Theme.ui.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(alignment: .trailing) {
            HStack(spacing: Theme.Space.iconGap) { actions }
                .padding(.trailing, Theme.historyRowPaddingH)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(active)
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.canRun(item) { model.selection = item.id; run(model.primaryAction(item)) } }
        .onHover { inside in
            if inside { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil }
        }
        .help(help)
        .padding(.horizontal, Theme.historyRowInset)
        .pointingHand(model.canRun(item))
    }

    // MARK: Columns

    @ViewBuilder private var icon: some View {
        switch item {
        case .conversation(let r): IconView(icon: r.conversation.agent == .claude ? .claude : .codex, size: Theme.Icon.toolbar)
        case .session: IconView(icon: .shell, size: Theme.Icon.toolbar, tint: Theme.ui.text2)
        }
    }

    private var title: String {
        switch item {
        case .conversation(let r): r.conversation.title ?? L10n.sessionsUntitled
        case .session(let r): r.name
        }
    }

    private var projectPlace: (Icon?, String?) {
        switch item {
        case .conversation(let r):
            (r.inWorktree ? .branch : .project, r.conversation.gitBranch ?? (r.folder as NSString).lastPathComponent)
        case .session(let r): (r.branch == nil ? nil : .branch, r.branch)
        }
    }

    /// Folder = the project's main folder, ⎇ = a worktree; then the branch (a session row: its worktree branch only).
    @ViewBuilder private var place: some View {
        let (glyph, text): (Icon?, String?) = isChat ? (nil, chatName) : projectPlace
        HStack(spacing: Theme.historyColumnGap) {
            if let glyph { IconView(icon: glyph, size: Theme.Icon.inline, tint: Theme.ui.text3) }
            if let text {
                Text(verbatim: text).font(isChat ? Theme.Typography.secondary.font() : Theme.Typography.monoSmall.font()).foregroundStyle(Theme.ui.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// A row of «Чаты»: its chat's name instead of folder and branch; no «в архиве» / «в истории».
    private var isChat: Bool {
        switch item {
        case .conversation(let r): r.project == chatsGroupId
        case .session(let r): r.project == chatsGroupId
        }
    }

    private var chatName: String? {
        switch item {
        case .conversation(let r): r.placeName
        case .session: nil
        }
    }

    @ViewBuilder private var state: some View {
        HStack(spacing: Theme.historyColumnGap) {
            switch isChat && item.state != .open ? nil : item.state {
            case nil: EmptyView()
            case .open:
                if case .conversation(let r) = item, case .open(_, let leaf, _) = r.place { StatusDot(state: app.state(ofLeaf: leaf)) }
                Text(L10n.sessionsMarkerOpen).foregroundStyle(Theme.ui.text1)
            case .archived:
                IconView(icon: .archive, size: Theme.Icon.inline, tint: Theme.ui.text3)
                Text(L10n.sessionsMarkerArchived).foregroundStyle(Theme.ui.text3)
            case .history:
                Text(L10n.sessionsMarkerHistory).foregroundStyle(Theme.ui.text3)
            }
        }
        .font(Theme.Typography.secondary.font())
        .lineLimit(1)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        let action = model.primaryAction(item)
        switch action {
        case .focus: button(L10n.sessionsGo, help: nil, action)
        case .restore where isChat:
            // An asleep chat without a project: it wakes; «Убрать из списка» instead of deleting.
            if let task = item.archivedTask {
                Button { model.delete(task, ctx: ctx) } label: {
                    IconView(icon: .remove, size: Theme.Icon.inline).frame(width: ControlSize.small.height - 2 * ControlSize.small.paddingH)
                }
                .buttonStyle(.hangar(.destructive, .small))
                .help(L10n.removeFromList)
            }
            button(L10n.sessionsContinue, help: nil, action)
        case .restore:
            if let task = item.archivedTask {
                Button { model.delete(task, ctx: ctx) } label: {
                    // A square: the style's side paddings make it exactly as wide as it is high.
                    IconView(icon: .trash, size: Theme.Icon.inline).frame(width: ControlSize.small.height - 2 * ControlSize.small.paddingH)
                }
                .buttonStyle(.hangar(.destructive, .small))
                .help(L10n.deletePermanently)
            }
            let offline = model.offlineHost(item)
            button(L10n.restore, help: offline.map(L10n.sessionsOffline) ?? L10n.sessionsRestoreHelp, action)
                .disabled(offline != nil)
        case .open(_, let task):
            button(L10n.sessionsContinue, help: L10n.sessionsContinueIn(app.state.tasks.first { $0.id == task }?.name ?? ""), action)
        case .openInNewSession, .openInNewFreeChat: button(L10n.sessionsContinue, help: L10n.sessionsContinueNew, action)
        }
    }

    /// «Продолжить» and the like are regular buttons (§3.8): the accent stays with the selected row.
    private func button(_ title: String, help: String?, _ action: SessionsAction) -> some View {
        Button(title) { run(action) }
            .buttonStyle(.hangar(.secondary, .small))
            .help(help ?? "")
    }

    // MARK: Text

    /// The full title, the Hangar session, the path and the message count; an archived session: its tabs, branch, date.
    private var help: String {
        switch item {
        case .conversation(let r):
            let c = r.conversation
            return [c.title, r.placeName.map(L10n.sessionsHelpSession), c.cwd,
                    (c.messageCountIsEstimate ? "~" : "") + L10n.sessionsMessages(c.messageCount)]
                .compactMap { $0 }.joined(separator: "\n")
        case .session(let r):
            let head = L10n.sessionsArchivedHelp(r.name, L10n.sessionsTabs(r.tabs)) + (r.branch.map { ", ⎇ " + $0 } ?? "")
            return [head, r.archivedAt.map { L10n.sessionsArchivedSince(day($0)) }].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// «12:40», «вчера», «21 окт.», «21 окт. 2025».
    private var time: String {
        let d = item.date
        guard d != .distantPast else { return "" }
        if model.scope == .chats { return formatted(d, "HH:mm") }  // the day is the group's heading
        switch historyDay(d, now: model.now(), calendar: model.calendar) {
        case .today: return formatted(d, "HH:mm")
        case .yesterday: return L10n.sessionsYesterday
        case .date: return day(d)
        }
    }

    private func day(_ d: Date) -> String {
        formatted(d, model.calendar.isDate(d, equalTo: model.now(), toGranularity: .year) ? "dMMM" : "dMMMyyyy")
    }

    private func formatted(_ d: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.resolve(L10n.language).rawValue)
        f.calendar = model.calendar
        f.timeZone = model.calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }
}

/// A host's or this Mac's note in the list: spinner or status dot, text (`text3`), an optional button; same height as a row.
struct SessionsNoteRow: View {
    let text: String
    let help: String?
    var spinner = false
    var dot: AgentState?
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: Theme.historyRowGap) {
            if spinner { ProgressView().controlSize(.mini).frame(width: Theme.Icon.toolbar) }
            if let dot { StatusDot(state: dot).frame(width: Theme.Icon.toolbar) }
            Text(verbatim: text).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
                .lineLimit(1).truncationMode(.tail)
                .help(help ?? "")
            if let button { Button(button, action: action).buttonStyle(.hangar(.secondary, .small)) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.historyRowPaddingH)
        .frame(height: Theme.historyRowHeight)
        .padding(.horizontal, Theme.historyRowInset)
    }
}
