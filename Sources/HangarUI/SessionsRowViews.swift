import AgentStatus
import History
import SwiftUI
import Workspace

/// A group heading, 34: chevron, project (semibold), host only for the scope «Все», row count right. A click folds it.
struct SessionsGroupHeader: View {
    let group: SessionsGroup
    let showHost: Bool
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.historyGroupGap) {
                IconView(icon: collapsed ? .chevronRight : .chevronDown, size: Theme.historyGroupIcon, tint: Theme.ui.text3)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - Theme.historyGroupBottom / 3 }
                Text(verbatim: group.name).font(Theme.Typography.body.font(.semibold)).foregroundStyle(Theme.ui.text)
                    .lineLimit(1)
                if showHost, let host = group.host {
                    HStack(spacing: Theme.historyColumnGap - 1) {
                        IconView(icon: .sshHost, size: Theme.historyHostIcon, tint: Theme.ui.text3)
                        Text(verbatim: host).font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !group.items.isEmpty {
                    Text(verbatim: "\(group.items.count)").font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3)
                }
            }
            .padding(.horizontal, Theme.historyPaddingH)
            .padding(.bottom, Theme.historyGroupBottom)
            .frame(height: Theme.historyGroupHeight, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}

/// A row: agent (or terminal) icon · title · where (folder / ⎇ and branch, mono) · state word · time. Under the pointer
/// the state and time give way to the actions (B′: one `primary`, the trash beside «Восстановить»); nothing moves.
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
                .font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3).lineLimit(1)
                .frame(width: Theme.historyTimeWidth, alignment: .trailing)
                .opacity(active ? 0 : 1)
        }
        .font(Theme.Typography.body.font())
        .foregroundStyle(Theme.ui.text)
        .padding(.horizontal, Theme.historyRowPaddingH)
        .frame(height: Theme.historyRowHeight)
        .background(selected ? Theme.ui.selection : hovered ? Theme.ui.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.historyRowRadius))
        .overlay(alignment: .trailing) {
            HStack(spacing: Theme.historyActionGap) { actions }
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
        case .conversation(let r): IconView(icon: r.conversation.agent == .claude ? .claude : .codex, size: Theme.historyRowIcon)
        case .session: IconView(icon: .shell, size: Theme.historyRowIcon, tint: Theme.ui.text2)
        }
    }

    private var title: String {
        switch item {
        case .conversation(let r): r.conversation.title ?? L10n.sessionsUntitled
        case .session(let r): r.name
        }
    }

    /// Folder = the project's main folder, ⎇ = a worktree; then the branch (a session row: its worktree branch only).
    @ViewBuilder private var place: some View {
        let (glyph, text): (Icon?, String?) = switch item {
        case .conversation(let r):
            (r.inWorktree ? .branch : .project, r.conversation.gitBranch ?? (r.folder as NSString).lastPathComponent)
        case .session(let r): (r.branch == nil ? nil : .branch, r.branch)
        }
        HStack(spacing: Theme.historyColumnGap) {
            if let glyph { IconView(icon: glyph, size: Theme.historyColumnIcon, tint: Theme.ui.text3) }
            if let text {
                Text(verbatim: text).font(Theme.Typography.mono.font()).foregroundStyle(Theme.ui.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var state: some View {
        HStack(spacing: Theme.historyColumnGap) {
            switch item.state {
            case .open:
                if case .conversation(let r) = item, case .open(_, let leaf, _) = r.place { StatusDot(state: app.state(ofLeaf: leaf)) }
                Text(L10n.sessionsMarkerOpen).foregroundStyle(Theme.ui.text)
            case .archived:
                IconView(icon: .archive, size: Theme.historyStateIcon, tint: Theme.ui.text3)
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
        case .focus: primary(L10n.sessionsGo, help: nil, action)
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
            primary(L10n.restore, help: offline.map(L10n.sessionsOffline) ?? L10n.sessionsRestoreHelp, action)
                .disabled(offline != nil)
        case .open(_, let task):
            primary(L10n.sessionsContinue, help: L10n.sessionsContinueIn(app.state.tasks.first { $0.id == task }?.name ?? ""), action)
        case .openInNewSession: primary(L10n.sessionsContinue, help: L10n.sessionsContinueNew, action)
        }
    }

    private func primary(_ title: String, help: String?, _ action: SessionsAction) -> some View {
        Button(title) { run(action) }
            .buttonStyle(.hangar(.primary, .small))
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
            if spinner { ProgressView().controlSize(.mini).frame(width: Theme.historyRowIcon) }
            if let dot { StatusDot(state: dot).frame(width: Theme.historyRowIcon) }
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
