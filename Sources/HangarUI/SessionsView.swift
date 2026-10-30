import AgentStatus
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

/// «Сессии» v2 (#107, sessions-v2.html variant A): title, scope segment and search; the chips; one list by project.
struct SessionsView: View {
    let app: AppState
    @Bindable var model: SessionsModel
    let ctx: ActionContext
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            chips
            Rectangle().fill(Theme.ui.line).frame(height: 1)
            if let p = model.placeholder { placeholder(p) } else { list }
        }
        .background(Theme.ui.bg0)
        .task(id: reloadKey) { await model.reload() }
        .onAppear {
            model.clearPointer()
            searchFocused = true
        }
        .onDisappear { model.clearPointer() }
    }

    /// A rescan when the scope or the project chip changes, or a host connects, drops or gives up (no watchers otherwise).
    private var reloadKey: String {
        model.loadKey + "|" + app.sessionsHosts.map { "\($0)=\(sessionsHostLink(app.remote.hosts[$0]))" }.joined(separator: ",")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.historyHeaderGap) {
            Text(L10n.sessionsTitle)
                .font(Theme.Typography.title.font(.semibold))
                .foregroundStyle(Theme.ui.text0)
                .fixedSize()
            // Only remote projects make a scope worth choosing.
            if !app.sessionsHosts.isEmpty { SessionsScopeSegment(app: app, scope: model.scope).fixedSize() }
            Spacer(minLength: 0)
            TextField(text: $model.query) { EmptyView() }
                .focused($searchFocused)
                .onKeyPress(.downArrow) { model.step(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.step(by: -1); return .handled }
                .onSubmit { if let a = model.activateSelection() { run(a) } }
                .inputField(focused: searchFocused, icon: .search, placeholder: model.query.isEmpty ? L10n.sessionsSearch : nil)
                .frame(minWidth: Theme.historySearchWidth / 2, maxWidth: Theme.historySearchWidth)
        }
        .padding(.leading, Theme.historyPaddingH)
        .padding(.trailing, Theme.historyPaddingTrailing)
        .frame(height: Theme.historyHeaderHeight)
    }

    /// Agent | state chips (none chosen = all); «Сбросить» keeps its place while hidden, so nothing moves.
    private var chips: some View {
        HStack(spacing: Theme.historyChipGap) {
            if let p = model.project {
                SessionsProjectChip(title: L10n.sessionsProjectChip(p.name)) { model.clearProject() }
                separator
            }
            Chip(title: "Claude", on: model.agents.contains(.claude), toggles: true) { model.toggle(.claude) }
            Chip(title: "Codex", on: model.agents.contains(.codex), toggles: true) { model.toggle(.codex) }
            separator
            Chip(title: L10n.sessionsChipOpen, on: model.states.contains(.open), toggles: true) { model.toggle(.open) }
            Chip(title: L10n.sessionsChipArchived, on: model.states.contains(.archived), toggles: true) { model.toggle(.archived) }
            Chip(title: L10n.sessionsChipHistory, on: model.states.contains(.history), toggles: true) { model.toggle(.history) }
            Spacer(minLength: 0)
            let chosen = !model.agents.isEmpty || !model.states.isEmpty
            Button(L10n.sessionsReset) { model.resetChips() }
                .buttonStyle(.hangar(.plain, .small))
                .opacity(chosen ? 1 : 0)
                .allowsHitTesting(chosen)
                .accessibilityHidden(!chosen)
        }
        .padding(.leading, Theme.historyPaddingH)
        .padding(.trailing, Theme.historyPaddingTrailing)
        .frame(height: Theme.historyFilterHeight)
    }

    private var separator: some View {
        Rectangle().fill(Theme.ui.line)
            .frame(width: Theme.historyChipSeparator.width, height: Theme.historyChipSeparator.height)
            .padding(.horizontal, Theme.historyChipGap)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let f = model.localFailure {
                        SessionsNoteRow(text: L10n.sessionsLoadFailedLocal(f.message), help: nil, dot: .waiting,
                                        button: L10n.retry) { Task { await model.reload() } }
                    }
                    ForEach(model.groups) { g in
                        SessionsGroupHeader(group: g, showHost: model.scope == .all, collapsed: model.collapsed.contains(g.id)) {
                            model.toggleCollapsed(g.id)
                        }
                        ForEach(model.visibleItems(g)) { item in
                            SessionsRow(app: app, model: model, item: item, ctx: ctx, run: run).id(item.id)
                        }
                        let hidden = model.hiddenCount(g)
                        if hidden > 0 {
                            HStack {
                                Button(L10n.sessionsShowMore(hidden)) { model.expanded.insert(g.id) }
                                    .buttonStyle(.hangar(.plain, .small))
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, Theme.historyMoreLeading - ControlSize.small.paddingH)
                            .frame(height: Theme.historyMoreHeight)
                        }
                        if let note = g.note, !model.collapsed.contains(g.id), let host = g.host { noteRow(note, host: host) }
                    }
                }
                .padding(.bottom, Theme.historyListBottom)
            }
            .background(SessionsScrollFollower(model: model, proxy: proxy))
        }
    }

    @ViewBuilder private func noteRow(_ note: SessionsNote, host: String) -> some View {
        switch note {
        case .loading: SessionsNoteRow(text: L10n.sessionsReadingHost(host), help: nil, spinner: true)
        case .failed(let f):
            let seconds = Int(model.remoteTimeout.components.seconds)
            SessionsNoteRow(text: f.timedOut ? L10n.sessionsHostTimedOut(host, seconds) : L10n.sessionsHostFailed(host),
                            help: f.timedOut ? nil : f.message, dot: .waiting, button: L10n.retry) { Task { await model.reload() } }
        case .offline:
            SessionsNoteRow(text: L10n.sessionsOffline(host), help: nil, dot: .idle, button: L10n.sessionsConnect) { app.reconnect(host: host) }
        }
    }

    // MARK: Centered states

    private func placeholder(_ p: SessionsPlaceholder) -> some View {
        VStack(spacing: Theme.historyCenterGap) {
            switch p {
            case .loading:
                HStack(spacing: Theme.historyRowGap) {
                    ProgressView().controlSize(.small)
                    Text(L10n.sessionsLoading).foregroundStyle(Theme.ui.text3)
                }
            case .offline(let host):
                Text(L10n.sessionsOffline(host)).font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.text1)
                Text(L10n.sessionsOfflineHint).foregroundStyle(Theme.ui.text3)
                Button(L10n.sessionsConnect) { app.reconnect(host: host) }.buttonStyle(.hangar(.primary, .small))
            case .empty:
                Text(L10n.sessionsEmpty).foregroundStyle(Theme.ui.text3)
            case .noMatch:
                let q = model.query.trimmingCharacters(in: .whitespaces)
                Text(q.isEmpty ? L10n.sessionsNoMatch : L10n.sessionsNoMatchQuery(q))
                    .font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.text1)
                Button(L10n.sessionsResetFilters) { model.resetFilters() }.buttonStyle(.hangar(.secondary, .small))
            }
        }
        .font(Theme.Typography.body.font())
        .multilineTextAlignment(.center)
        .frame(maxWidth: Theme.historyCenterHintWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run(_ action: SessionsAction) {
        Task { await model.perform(action, ctx: ctx) }
    }
}

/// «Все» / «Этот Mac» / hosts (more than `historyScopeMaxHosts` — «Ещё ▾», a menu of the rest): one `Segmented`.
struct SessionsScopeSegment: View {
    let app: AppState
    let scope: SessionsScope

    /// A part of the segment: a scope, or «Ещё» standing for the hosts that didn't fit.
    private enum Part: Hashable { case scope(SessionsScope), more }

    var body: some View {
        let hosts = app.sessionsHosts
        let shown = hosts.count > Theme.historyScopeMaxHosts ? Array(hosts.prefix(Theme.historyScopeMaxHosts)) : hosts
        let rest = hosts.filter { !shown.contains($0) }
        let chosen = rest.first { scope == .host($0) }
        var options = [SegmentOption<Part>(value: .scope(.all), title: L10n.sessionsAll)]
        if app.state.projects.contains(where: { $0.host == nil }) {
            options.append(SegmentOption(value: .scope(.local), title: L10n.thisMac, icon: .mac))
        }
        options += shown.map { SegmentOption(value: .scope(.host($0)), title: $0, icon: .sshHost, dot: dot($0)) }
        if !rest.isEmpty {
            options.append(SegmentOption(value: .more, title: chosen ?? L10n.sessionsMore, icon: chosen == nil ? nil : .sshHost,
                                         dot: chosen.map(dot)) {
                rest.map { h in .item(PopoverMenuItem(title: h, icon: .sshHost, checked: scope == .host(h), dot: dot(h)) {
                    app.showSessionsView(scope: .host(h))
                }) }
            })
        }
        return Segmented(selection: chosen == nil ? Part.scope(scope) : .more, options: options) { part in
            if case .scope(let s) = part { app.showSessionsView(scope: s) }
        }
    }

    /// The host's link: `done` connected, `idle` not.
    private func dot(_ host: String) -> AgentState { app.remote.hosts[host]?.state == .connected ? .done : .idle }
}

/// «Проект: shop ×»: a chosen chip; a click anywhere on it removes it.
private struct SessionsProjectChip: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: Theme.Space.iconGap) {
                Text(verbatim: title).truncationMode(.middle)
                IconView(icon: .close, size: Theme.Icon.inline, tint: Theme.ui.accentText)
            }
        }
        .buttonStyle(ChipStyle(on: true))
        .help(L10n.sessionsProjectChipHelp)
        .accessibilityAddTraits(.isSelected)
    }
}

/// Scrolls to the keyboard's row; its own view, so a selection change does not redraw the whole list.
private struct SessionsScrollFollower: View {
    let model: SessionsModel
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear.onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
    }
}
