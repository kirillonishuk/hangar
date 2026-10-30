import SwiftUI
import Usage
import Workspace

// MARK: Texts

/// «5 часов», «Неделя · все модели» (claude) / «Неделя» (codex), «Неделя · Opus».
@MainActor func limitWindowTitle(_ kind: WindowKind, agent: UsageAgent) -> String {
    switch kind {
    case .session: L10n.limitSession
    case .weekly: agent == .claude ? L10n.limitWeekAll : L10n.limitWeek
    case .weeklyModel(let model): L10n.limitWeekModel(model.prefix(1).uppercased() + model.dropFirst())
    }
}

@MainActor private var resetFormatters: [Language: DateFormatter] = [:]

/// «сброс через 1 ч 12 мин · 16:40»; a day or more away — «сброс через 2 дн 4 ч · вс 13:20».
@MainActor func resetLabel(_ resetsAt: Date, now: Date, calendar: Calendar) -> String {
    let minutes = max(1, Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up)))
    let duration = minutes < 60 ? L10n.durationMin(minutes)
        : minutes < 24 * 60 ? L10n.durationHourMin(minutes / 60, minutes % 60)
        : L10n.durationDayHour(minutes / (24 * 60), minutes / 60 % 24)
    return L10n.resetIn(duration, resetClock(resetsAt, now: now, calendar: calendar))
}

/// «20:20», a day or more ahead «пн 20:20».
@MainActor func resetClock(_ resetsAt: Date, now: Date, calendar: Calendar) -> String {
    let lang = L10n.resolve(L10n.language)
    let f = resetFormatters[lang] ?? {
        let f = DateFormatter()
        f.locale = Locale(identifier: lang.rawValue)
        resetFormatters[lang] = f
        return f
    }()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = "HH:mm"
    var time = f.string(from: resetsAt)
    if Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up)) >= 24 * 60 {  // the same rounding as the duration
        f.dateFormat = "EEE"
        let day = f.string(from: resetsAt)
        // Russian weekdays are lowercase mid-sentence; macOS returns «Вс».
        time = (lang == .ru ? day.lowercased(with: f.locale) : day) + " " + time
    }
    return time
}

/// One macOS notification per crossed threshold; `limit-<agent>` replaces the agent's previous one.
@MainActor func limitNotice(_ alert: UsageAlert) -> AgentNotice {
    let agent = agentName(alert.agent)  // «Claude», as in the attention banners
    let title: String
    if alert.level != .full, let p = alert.percent { title = L10n.limitAlmost(agent, Int(p.rounded())) }
    else { title = L10n.limitReached(agent) }
    let subtitle = alert.kind.map { limitWindowTitle($0, agent: alert.agent) } ?? ""
    return AgentNotice(id: "limit-\(alert.agent.rawValue)", title: title, subtitle: subtitle, body: "", leaf: nil, category: .limit, thread: nil,
                       sound: "default", requestKey: nil)
}

/// Gated by the master `notifications` switch and `limit_notifications`; the sound is `sound_limit`.
@MainActor func limitNotices(_ alerts: [UsageAlert], app: AppState) -> [AgentNotice] {
    guard app.config.notifications, app.config.limitNotifications else { return [] }
    return alerts.map { var n = limitNotice($0); n.sound = noticeSound(app.config.sounds["limit"]); return n }
}

private func agentName(_ agent: UsageAgent) -> String {
    switch agent {
    case .claude: "Claude"
    case .codex: "Codex"
    }
}

private func rank(_ kind: WindowKind) -> String {
    switch kind {
    case .session: "0"
    case .weekly: "1"
    case .weeklyModel(let m): "2" + m
    }
}

/// A reached limit colors the fullest window red too.
private func windowLevel(_ w: UsageWindow, in u: AgentUsage) -> UsageLevel {
    let top = u.windows.map(\.usedPercent).max() ?? 0
    return level(percent: w.usedPercent, limitReached: u.limitReached && w.usedPercent == top)
}

/// A reached limit with no window rows yet: the agent gets the «лимит» badge under its name instead.
func limitBadgeWithoutWindows(_ u: AgentUsage) -> Bool { u.limitReached && u.windows.isEmpty }

private func percentText(_ p: Double) -> String { "\(Int(p.rounded()))%" }

// MARK: Views

/// «лимит» / «почти»: a tinted capsule.
private struct LimitBadge: View {
    let level: UsageLevel

    var body: some View {
        Text(level == .full ? L10n.limitBadgeFull : L10n.limitBadgeAlmost)
            .font(Theme.Typography.caption.font())
            .foregroundStyle(Theme.Limit.textColor(level))
            .padding(.horizontal, Theme.Badge.paddingH)
            .frame(height: Theme.Badge.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Limit.color(level).opacity(Theme.Opacity.fill)))
    }
}

private struct LimitBar: View {
    var percent: Double?
    var level: UsageLevel = .ok
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Limit.track)
                if let percent, percent > 0 {
                    Capsule().fill(Theme.Limit.color(level))
                        .frame(width: geo.size.width * min(percent, 100) / 100)
                }
            }
        }
        .frame(height: height)
    }
}

/// Sidebar block above the bottom bar: a row per agent with data; a click opens the popover.
struct LimitsBlock: View {
    let app: AppState

    var body: some View {
        VStack(spacing: Theme.railInset) {
            ForEach(app.limitRows, id: \.agent) { row in
                Button { app.limitsClicked() } label: { line(row.agent, row.usage) }
                    .buttonStyle(HoverButtonStyle(radius: Theme.Radius.control))
                    .help(L10n.help(L10n.limitsHelp, .limits))
            }
        }
        .padding(.vertical, Theme.Limit.blockPaddingV)
        .padding(.horizontal, Theme.Limit.blockPaddingH)
        // Up from the block's right corner: beside it the popover would cover the «Терминал» bar, centred over it
        // it would stick out of the window's left edge.
        .popover(isPresented: Binding(get: { app.limitsPopoverShown }, set: { app.setLimitsPopoverShown($0) }),
                 attachmentAnchor: .point(UnitPoint(x: 0.8, y: 0)), arrowEdge: .top) {
            LimitsPopover(app: app)
        }
    }

    /// «claude  5 ч ━━━ 6%» over «нед ━━━ 25%»: both windows always, «—» while one has no figure yet.
    private func line(_ agent: UsageAgent, _ u: AgentUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Limit.rowGap) {
            Text(agent.rawValue)
                .font(Theme.Typography.caption.font())
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1)
                .frame(width: Theme.Limit.nameWidth, alignment: .leading)
            VStack(spacing: Theme.Limit.barGap) {
                ForEach(LimitSlot.footer, id: \.self) { kind in windowLine(kind, u) }
            }
        }
        .padding(.vertical, Theme.Limit.rowPaddingV)
        .padding(.horizontal, Theme.Limit.rowPaddingH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agentName(agent)) \(LimitSlot.footer.map { "\(limitWindowTitle($0, agent: agent)) \(LimitSlot.figure($0, u).map(percentText) ?? "—")" }.joined(separator: ", "))")
    }

    private func windowLine(_ kind: WindowKind, _ u: AgentUsage) -> some View {
        let percent = LimitSlot.figure(kind, u)
        let level = LimitSlot.level(kind, u)
        return HStack(spacing: Theme.Space.s1) {
            Text(kind == .session ? L10n.limitSessionShort : L10n.limitWeekShort)
                .foregroundStyle(Theme.ui.text3)
                .fixedSize()  // never «we…»: a longer word only shortens the bar
                .frame(minWidth: Theme.Limit.windowLabelWidth, alignment: .leading)
            LimitBar(percent: percent, level: level, height: Theme.Limit.blockBar)
            Text(percent.map(percentText) ?? "—")
                .monospacedDigit()
                .foregroundStyle(percent == nil ? Theme.ui.text3 : Theme.Limit.textColor(level))
                .frame(width: Theme.Limit.percentWidth, alignment: .trailing)
        }
        .font(Theme.Typography.caption.font())
    }
}

/// The 5-hour and weekly windows are always shown (sidebar and popover), with «—» while one has no figure.
enum LimitSlot {
    static let footer: [WindowKind] = [.session, .weekly]

    /// The window's figure; a reached limit with no window data yet (StopFailure first) reads 100.
    static func figure(_ kind: WindowKind, _ u: AgentUsage) -> Double? {
        u.windows.first { $0.kind == kind }?.usedPercent ?? (u.windows.isEmpty && u.limitReached ? 100 : nil)
    }

    static func level(_ kind: WindowKind, _ u: AgentUsage) -> UsageLevel {
        if let w = u.windows.first(where: { $0.kind == kind }) { return windowLevel(w, in: u) }
        return u.windows.isEmpty && u.limitReached ? .full : .ok
    }

    /// Popover rows: both main windows (present or not), then whatever per-model windows came, in a stable order.
    static func rows(_ u: AgentUsage) -> [(kind: WindowKind, window: UsageWindow?)] {
        footer.map { k in (k, u.windows.first { $0.kind == k }) }
            + u.windows.filter { !footer.contains($0.kind) }.sorted { rank($0.kind) < rank($1.kind) }.map { ($0.kind, $0) }
    }
}

/// Rail: one gauge icon tinted by the worst level; a click opens the same popover.
struct LimitsRailTile: View {
    let app: AppState

    var body: some View {
        let worst = app.limitRows.compactMap { app.usage.level($0.agent, now: app.usageClock) }.max() ?? .ok
        HoverRow(action: { app.limitsClicked() }) { _ in
            GutterRow(collapsed: true, height: Theme.Height.rowSidebar) {
                IconView(icon: .limits, tint: Theme.Limit.color(worst))
            } expanded: { EmptyView() } rail: { EmptyView() }
        }
        .help(L10n.help(L10n.limitsHelp, .limits))
        .accessibilityLabel(L10n.limitsHelp)
        .popover(isPresented: Binding(get: { app.limitsPopoverShown }, set: { app.setLimitsPopoverShown($0) }),
                 attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: Theme.sidebarRailWidth, height: Theme.Height.rowSidebar))),
                 arrowEdge: .trailing) {
            LimitsPopover(app: app)
        }
    }
}

/// Plan, «обновлено …», each window with badge, percent, bar and reset time; ⇧⌘L hint and ↻.
struct LimitsPopover: View {
    let app: AppState

    var body: some View {
        let rows = app.limitRows
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.agent) { i, row in
                if i > 0 { Rectangle().fill(Theme.ui.line2).frame(height: 1).padding(.horizontal, -Theme.Limit.popoverPaddingH) }
                agent(row.agent, row.usage)
                    .padding(.vertical, Theme.Limit.itemGap / 2)
            }
            HStack {
                Text(L10n.help(L10n.limitsShortcutHint, .limits))
                Spacer(minLength: Theme.Limit.rowGap)
                Button {
                    app.refreshUsageClock()
                    Task { await app.refreshCodexUsage(afterTurn: false) }
                } label: {
                    // A header action: unfilled until hovered, so it doesn't read as the `text3` hint beside it.
                    ActionLabel(title: L10n.refresh, icon: .refresh)
                }
                .buttonStyle(.hangar(.plain, .small))
                .help(L10n.refreshLimitsHelp)
            }
            .font(Theme.Typography.caption.font())
            .foregroundStyle(Theme.ui.text3)
            .padding(.top, Theme.railInset)
        }
        .padding(.vertical, Theme.Limit.popoverPaddingV)
        .padding(.horizontal, Theme.Limit.popoverPaddingH)
        .frame(width: Theme.Limit.popoverWidth)
        .presentationBackground(Theme.ui.bg2)
    }

    private func agent(_ agent: UsageAgent, _ u: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Limit.itemGap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Limit.rowGap) {
                Text(agentName(agent)).font(Theme.Typography.body.font(.semibold)).foregroundStyle(Theme.ui.text0)
                if let plan = u.plan { Text(plan).foregroundStyle(Theme.ui.text2) }
                Spacer(minLength: 0)
                Text(L10n.updatedAgo(ageLabel(since: u.updatedAt, now: app.usageClock)))
                    .font(Theme.Typography.monoSmall.font())
                    .foregroundStyle(Theme.ui.text3)
            }
            .font(Theme.Typography.caption.font())
            // Its own line: next to the name it would push «обновлено …» onto two lines.
            if limitBadgeWithoutWindows(u) { LimitBadge(level: .full) }
            ForEach(LimitSlot.rows(u), id: \.kind) { row in
                if let w = row.window { window(w, agent: agent, level: windowLevel(w, in: u)) }
                else { missing(row.kind, agent: agent) }
            }
        }
    }

    /// A main window the agent sent no figure for yet: kept in place, so the 5-hour row never just disappears.
    private func missing(_ kind: WindowKind, agent: UsageAgent) -> some View {
        VStack(alignment: .leading, spacing: Theme.railInset) {
            HStack(spacing: Theme.Limit.rowGap) {
                Text(limitWindowTitle(kind, agent: agent)).fontWeight(.semibold).foregroundStyle(Theme.ui.text1)
                Spacer(minLength: 0)
                Text(verbatim: "—").foregroundStyle(Theme.ui.text3)
            }
            .font(Theme.Typography.secondary.font())
            LimitBar(percent: nil, height: Theme.Limit.popoverBar)
            Text(L10n.limitNoData)
                .font(Theme.Typography.caption.font())
                .foregroundStyle(Theme.ui.text3)
        }
    }

    private func window(_ w: UsageWindow, agent: UsageAgent, level: UsageLevel) -> some View {
        VStack(alignment: .leading, spacing: Theme.railInset) {
            HStack(spacing: Theme.Limit.rowGap) {
                Text(limitWindowTitle(w.kind, agent: agent)).fontWeight(.semibold).foregroundStyle(Theme.ui.text1)
                Spacer(minLength: 0)
                if level > .ok { LimitBadge(level: level) }
                Text(percentText(w.usedPercent)).monospacedDigit().foregroundStyle(Theme.ui.text2)
            }
            .font(Theme.Typography.secondary.font())
            LimitBar(percent: w.usedPercent, level: level, height: Theme.Limit.popoverBar)
            if let r = w.resetsAt, r > app.usageClock {
                Text(resetLabel(r, now: app.usageClock, calendar: .current))
                    .font(Theme.Typography.caption.font())
                    .foregroundStyle(Theme.ui.text3)
            }
        }
    }
}
