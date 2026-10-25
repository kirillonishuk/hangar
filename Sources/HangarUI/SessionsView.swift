import History
import SwiftUI
import Workspace

/// Shown over the session area while `sessionsViewVisible` (the window hides this host otherwise).
struct SessionsHost: View {
    let app: AppState
    let model: SessionsModel
    let ctx: ActionContext

    var body: some View {
        if app.sessionsViewVisible { SessionsView(app: app, model: model, ctx: ctx) }
    }
}

/// «Сессии» (redesign-v1 §5): header with the project, agent segment and search; closed sessions, then conversations by day.
struct SessionsView: View {
    let app: AppState
    @Bindable var model: SessionsModel
    let ctx: ActionContext
    @State private var hovered: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.ui.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    group(L10n.sessionsClosed)
                    let closed = model.closedRows
                    if closed.isEmpty {
                        note(model.closedCount == 0 ? L10n.sessionsNoClosed : L10n.sessionsNoMatch)
                    } else {
                        ForEach(closed) { closedRow($0) }
                    }
                    conversations
                }
                .padding(.bottom, Theme.historyListBottom)
            }
        }
        .background(Theme.ui.bg)
        .task(id: app.sessionsProjectId) { await model.reload() }
        .onAppear { searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.historyHeaderGap) {
            HStack(spacing: Theme.historyCountsGap) {
                Text(L10n.sessionsTitle).font(.system(size: Theme.historyTitleSize, weight: .semibold)).foregroundStyle(Theme.ui.textStrong)
                projectPicker
                Text("· " + L10n.sessionsClosedCount(model.closedCount) + " · " + L10n.sessionsConversationCount(model.conversationCount))
                    .font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            segment
            search
        }
        .padding(.horizontal, Theme.historyPaddingH)
        .frame(height: Theme.historyHeaderHeight)
    }

    private var projectPicker: some View {
        let projects = app.state.projects
        let current = model.projectId.flatMap(app.project)
        return Menu {
            ForEach(projects) { p in
                Button(p.name) { app.showSessionsView(projectId: p.id) }
            }
        } label: {
            Text(current?.name ?? "").font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(projects.count < 2)
        .help(L10n.sessionsProjectHelp)
        .pointingHand(projects.count > 1)
        // A Menu label puts any image first: the chevron trails it from outside.
        .overlay(alignment: .trailing) {
            if projects.count > 1 {
                IconView(icon: .chevronDown, size: Theme.historyActionIcon, tint: Theme.ui.text3)
                    .offset(x: Theme.historyActionIcon + Theme.historyActionGap / 2).allowsHitTesting(false)
            }
        }
        .padding(.trailing, projects.count > 1 ? Theme.historyActionIcon : 0)
    }

    private var segment: some View {
        HStack(spacing: Theme.historySegmentPadding) {
            ForEach(SessionsAgentFilter.allCases, id: \.self) { f in
                let on = model.agent == f
                Button { model.agent = f } label: {
                    Text(title(f))
                        .font(.system(size: Theme.fontSize.segment))
                        .foregroundStyle(on ? Theme.ui.textStrong : Theme.ui.text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(on ? Theme.ui.control : .clear, in: RoundedRectangle(cornerRadius: Theme.historySegmentItemRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
        }
        .padding(Theme.historySegmentPadding)
        .frame(width: Theme.historySegmentWidth, height: Theme.historySearchHeight)
        .background(Theme.ui.field, in: RoundedRectangle(cornerRadius: Theme.historySegmentRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.historySegmentRadius).strokeBorder(Theme.ui.control))
    }

    private func title(_ f: SessionsAgentFilter) -> String {
        switch f {
        case .all: L10n.sessionsAll
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    private var search: some View {
        HStack(spacing: Theme.historySearchPaddingH) {
            IconView(icon: .search, size: Theme.historySearchIcon, tint: Theme.ui.text3)
            TextField(text: $model.query, prompt: Text(L10n.sessionsSearch).foregroundStyle(Theme.ui.text3)) { EmptyView() }
                .textFieldStyle(.plain)
                .font(.system(size: Theme.fontSize.base))
                .foregroundStyle(Theme.ui.text)
                .focused($searchFocused)
        }
        .padding(.horizontal, Theme.historySearchPaddingH)
        .frame(width: Theme.historySearchWidth, height: Theme.historySearchHeight)
        .background(Theme.ui.field, in: RoundedRectangle(cornerRadius: Theme.historySearchRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.historySearchRadius)
            .strokeBorder(searchFocused ? Theme.ui.accent : Theme.ui.control))
        .background(RoundedRectangle(cornerRadius: Theme.historySearchRadius)
            .fill(Theme.ui.accent.opacity(searchFocused ? Theme.historyFocusRingOpacity : 0))
            .padding(-Theme.focusRing))
    }

    // MARK: Groups

    private func group(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.fontSize.footer, weight: .semibold))
            .foregroundStyle(Theme.ui.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, Theme.historyPaddingH)
            .padding(.bottom, Theme.historyGroupBottom)
            .frame(height: Theme.historyGroupHeight)
    }

    /// Empty, loading and offline states: one quiet row, no frames.
    private func note(_ text: String, spinner: Bool = false) -> some View {
        HStack(spacing: Theme.historyRowGap) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.historyPaddingH)
        .frame(height: Theme.historyRowHeight)
    }

    @ViewBuilder private var conversations: some View {
        let days = model.days
        if days.isEmpty {
            group(L10n.sessionsConversations)
            switch model.load {
            case .idle, .loading: note(L10n.sessionsLoading, spinner: true)
            case .offline(let host): note(L10n.sessionsOffline(host))
            case .loaded: note(L10n.sessionsNoConversations)
            }
        } else {
            ForEach(days) { day in
                group(dayTitle(day.day))
                ForEach(day.rows) { conversationRow($0) }
            }
        }
    }

    // MARK: Rows

    private func closedRow(_ r: ClosedSessionRow) -> some View {
        let key = "closed:" + r.id.uuidString
        return row(key: key, action: { run(model.closedAction(r.id)) }) {
            IconView(icon: .archive, tint: Theme.ui.text2)
            Text(r.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            if let branch = r.branch { branchLabel(branch, mono: true) }
            if let c = r.changes, c.added + c.deleted > 0 { badge(c) }
            layout(r.tabLeaves)
            meta(tabSummary(r.tabLeaves), width: Theme.historyCountWidth, hidden: hovered == key)
            meta(r.closedAt.map(closedTime) ?? "", width: Theme.historyTimeWidth, hidden: hovered == key)
        } actions: {
            actionButton(icon: .trash, title: nil, help: L10n.deletePermanently) { model.delete(r.id, ctx: ctx) }
            actionButton(icon: .restore, title: L10n.restore, help: nil) { run(model.closedAction(r.id)) }
        }
    }

    private func conversationRow(_ r: ConversationRow) -> some View {
        let c = r.conversation
        let action = model.action(for: r)
        return row(key: r.id, action: { run(action) }) {
            IconView(icon: c.agent == .claude ? .claude : .codex)
            Text(c.title ?? L10n.sessionsUntitled).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            place(r)
            meta((c.messageCountIsEstimate ? "~" : "") + L10n.sessionsMessages(c.messageCount), width: Theme.historyCountWidth,
                 hidden: hovered == r.id)
            meta(time(c.lastActivity), width: Theme.historyTimeWidth, hidden: hovered == r.id)
        } actions: {
            switch action {
            case .focus: actionButton(icon: nil, title: L10n.sessionsGo, help: nil) { run(action) }
            case .restore: actionButton(icon: .restore, title: L10n.restore, help: nil) { run(action) }
            case .open, .openInNewSession: actionButton(icon: .openExternal, title: L10n.sessionsOpen, help: nil) { run(action) }
            }
        }
    }

    /// 36 high, inset 12, radius 8; hover = `hover` fill, the count and time fade out and the actions fade in over them.
    private func row<Content: View, Actions: View>(key: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content,
                                                   @ViewBuilder actions: () -> Actions) -> some View {
        let on = hovered == key
        return HStack(spacing: Theme.historyRowGap) { content() }
            .font(.system(size: Theme.fontSize.base))
            .foregroundStyle(Theme.ui.text)
            .padding(.horizontal, Theme.historyRowPaddingH)
            .frame(height: Theme.historyRowHeight)
            .background(on ? Theme.ui.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.historyRowRadius))
            .overlay(alignment: .trailing) {
                HStack(spacing: Theme.historyActionGap) { actions() }
                    .padding(.trailing, Theme.historyRowPaddingH)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(on)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { inside in
                if inside { hovered = key } else if hovered == key { hovered = nil }
            }
            .animation(Motion.reduced ? nil : .easeOut(duration: Theme.hoverFade), value: on)
            .padding(.horizontal, Theme.historyRowInset)
            .pointingHand()
    }

    private func actionButton(icon: Icon?, title: String?, help: String?, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: Theme.historyActionGap) {
                if let icon { IconView(icon: icon, size: Theme.historyActionIcon, tint: Theme.ui.textStrong) }
                if let title { Text(title).font(.system(size: Theme.fontSize.footer)) }
            }
            .foregroundStyle(Theme.ui.textStrong)
            .padding(.horizontal, title == nil ? 0 : Theme.historyActionPaddingH)
            .frame(minWidth: Theme.historyActionHeight, minHeight: Theme.historyActionHeight)
            .background(Theme.ui.hoverStrong, in: RoundedRectangle(cornerRadius: Theme.historyActionRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .pointingHand()
    }

    /// Count and time: a fixed minimum width keeps rows aligned; hidden (not removed) under the hover actions.
    private func meta(_ text: String, width: CGFloat, hidden: Bool) -> some View {
        Text(text)
            .font(.system(size: Theme.fontSize.footer))
            .foregroundStyle(Theme.ui.text3)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: width, alignment: .trailing)  // «yesterday 18:20» may be wider than the column
            .opacity(hidden ? 0 : 1)
    }

    private func branchLabel(_ branch: String, mono: Bool) -> some View {
        HStack(spacing: Theme.iconGap - 2) {
            IconView(icon: .branch, size: Theme.worktreeEndIcon, tint: Theme.ui.text3)
            Text(branch).font(.system(size: Theme.fontSize.footer, design: mono ? .monospaced : .default)).foregroundStyle(Theme.ui.text2)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// ⎇ branch and the session marker: «· открыт», «· закрыта», «без сессии».
    private func place(_ r: ConversationRow) -> some View {
        let branch = r.conversation.gitBranch ?? r.placeName
        return HStack(spacing: Theme.iconGap - 2) {
            switch r.place {
            case .open(let task, _, _):
                StatusDot(state: app.state.tasks.first { $0.id == task }.map(app.state(of:)) ?? .idle)
                Text((branch ?? "") + " · " + L10n.sessionsMarkerOpen).foregroundStyle(Theme.ui.text2)
            case .session:
                IconView(icon: .branch, size: Theme.worktreeEndIcon, tint: Theme.ui.text3)
                Text(branch ?? "").foregroundStyle(Theme.ui.text2)
            case .closed(_, let name):
                IconView(icon: .archive, size: Theme.worktreeEndIcon, tint: Theme.ui.text3)
                Text(name + " · " + L10n.sessionsMarkerClosed).foregroundStyle(Theme.ui.text3)
            case .none:
                Text(L10n.sessionsNoSession).foregroundStyle(Theme.ui.text3)
            }
        }
        .font(.system(size: Theme.fontSize.footer))
        .lineLimit(1)
        .fixedSize()
    }

    private func badge(_ c: LineChanges) -> some View {
        HStack(spacing: Theme.historyBadgeGap) {
            Text(verbatim: "+\(c.added)").foregroundStyle(Theme.Diff.badgeA)
            Text(verbatim: "−\(c.deleted)").foregroundStyle(Theme.Diff.badgeD)
        }
        .font(.system(size: Theme.fontSize.footer, design: .monospaced))
        .padding(.horizontal, Theme.historyBadgePaddingH)
        .frame(height: Theme.historyBadgeHeight)
        .background(Theme.ui.bg.opacity(Theme.historyBadgeFill), in: RoundedRectangle(cornerRadius: Theme.historyBadgeRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.historyBadgeRadius).strokeBorder(Theme.historyBadgeBorder))
        .fixedSize()
    }

    /// One box per tab (wider for a split one), like the mockup's `.lay`.
    private func layout(_ leaves: [Int]) -> some View {
        HStack(spacing: Theme.historyLayoutGap) {
            ForEach(Array(leaves.prefix(Theme.historyLayoutMax).enumerated()), id: \.offset) { _, n in
                RoundedRectangle(cornerRadius: Theme.historyLayoutRadius)
                    .strokeBorder(Theme.ui.text3, lineWidth: Theme.historyLayoutStroke)
                    .frame(width: n > 1 ? Theme.historyLayoutSplitWidth : Theme.historyLayoutBox.width, height: Theme.historyLayoutBox.height)
            }
        }
        .accessibilityHidden(true)
    }

    private func tabSummary(_ leaves: [Int]) -> String { L10n.sessionsTabs(leaves.count) }

    // MARK: Actions

    private func run(_ action: SessionsAction) {
        Task { await model.perform(action, ctx: ctx) }
    }

    // MARK: Dates

    private var locale: Locale { Locale(identifier: L10n.resolve(L10n.language).rawValue) }

    private func formatted(_ d: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = model.calendar
        f.timeZone = model.calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    private func time(_ d: Date) -> String { formatted(d, "HH:mm") }

    private func dayTitle(_ day: HistoryDay) -> String {
        switch day {
        case .today: L10n.sessionsToday
        case .yesterday: L10n.sessionsYesterday
        case .date(let d):
            formatted(d, model.calendar.isDate(d, equalTo: model.now(), toGranularity: .year) ? "dMMMMEEEE" : "dMMMMyyyy")
        }
    }

    /// «18:20», «вчера 18:20», «21 окт.», «21 окт. 2025».
    private func closedTime(_ d: Date) -> String {
        switch historyDay(d, now: model.now(), calendar: model.calendar) {
        case .today: time(d)
        case .yesterday: L10n.sessionsYesterdayAt(time(d))
        case .date: formatted(d, model.calendar.isDate(d, equalTo: model.now(), toGranularity: .year) ? "dMMM" : "dMMMyyyy")
        }
    }
}
