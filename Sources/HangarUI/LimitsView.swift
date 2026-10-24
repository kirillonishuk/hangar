import SwiftUI
import Usage
import Workspace

// MARK: Texts

/// «Сессия (5 ч)», «Неделя · все модели» (claude) / «Неделя» (codex), «Неделя · Opus».
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
    if minutes >= 24 * 60 {
        f.dateFormat = "EEE"
        let day = f.string(from: resetsAt)
        // Russian weekdays are lowercase mid-sentence; macOS returns «Вс».
        time = (lang == .ru ? day.lowercased(with: f.locale) : day) + " " + time
    }
    return L10n.resetIn(duration, time)
}

/// One macOS notification per crossed threshold; `limit-<agent>` replaces the agent's previous one.
@MainActor func limitNotice(_ alert: UsageAlert) -> AgentNotice {
    let agent = alert.agent.rawValue
    let title: String
    if alert.level != .full, let p = alert.percent { title = L10n.limitAlmost(agent, Int(p.rounded())) }
    else { title = L10n.limitReached(agent) }
    let subtitle = alert.kind.map { limitWindowTitle($0, agent: alert.agent) } ?? ""
    return AgentNotice(id: "limit-\(agent)", title: title, subtitle: subtitle, body: "", leaf: nil)
}

/// Gated by `limit_notifications`.
@MainActor func limitNotices(_ alerts: [UsageAlert], app: AppState) -> [AgentNotice] {
    app.config.limitNotifications ? alerts.map(limitNotice) : []
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

private func maxPercent(_ u: AgentUsage) -> Double { u.windows.map(\.usedPercent).max() ?? 0 }

private func percentText(_ p: Double) -> String { "\(Int(p.rounded()))%" }

// MARK: Views

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
                    .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                    .help(L10n.help(L10n.limitsHelp, .limits))
            }
        }
        .padding(.vertical, Theme.Limit.blockPaddingV)
        .padding(.horizontal, Theme.Limit.blockPaddingH)
        .popover(isPresented: Binding(get: { app.limitsPopoverShown }, set: { app.setLimitsPopoverShown($0) }), arrowEdge: .trailing) {
            LimitsPopover(app: app)
        }
    }

    private func line(_ agent: UsageAgent, _ u: AgentUsage) -> some View {
        let session = u.windows.first { $0.kind == .session }
        let week = u.windows.first { $0.kind == .weekly }
        let top = level(percent: maxPercent(u), limitReached: u.limitReached)
        return HStack(spacing: Theme.Limit.rowGap) {
            Text(agent.rawValue)
                .font(.system(size: Theme.Limit.nameFont))
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1)
                .frame(width: Theme.Limit.nameWidth, alignment: .leading)
            VStack(spacing: Theme.Limit.barGap) {
                LimitBar(percent: session?.usedPercent, level: session.map { windowLevel($0, in: u) } ?? .ok, height: Theme.Limit.blockBar)
                LimitBar(percent: week?.usedPercent, level: week.map { windowLevel($0, in: u) } ?? .ok, height: Theme.Limit.blockBar)
            }
            Text(percentText(maxPercent(u)))
                .font(.system(size: Theme.Limit.percentFont).monospacedDigit())
                .foregroundStyle(Theme.Limit.textColor(top))
                .frame(width: Theme.Limit.percentWidth, alignment: .trailing)
        }
        .padding(.vertical, Theme.Limit.rowPaddingV)
        .padding(.horizontal, Theme.Limit.rowPaddingH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agentName(agent)) \(percentText(maxPercent(u)))")
    }
}

/// Rail: one gauge icon tinted by the worst level; a click opens the same popover.
struct LimitsRailTile: View {
    let app: AppState

    var body: some View {
        let worst = app.limitRows.compactMap { app.usage.level($0.agent, now: app.usageClock) }.max() ?? .ok
        HoverRow(action: { app.limitsClicked() }) { _ in
            GutterRow(collapsed: true, height: Theme.footerRowHeight) {
                IconView(icon: .limits, tint: Theme.Limit.color(worst))
            } expanded: { EmptyView() } rail: { EmptyView() }
        }
        .help(L10n.help(L10n.limitsHelp, .limits))
        .accessibilityLabel(L10n.limitsHelp)
        .popover(isPresented: Binding(get: { app.limitsPopoverShown }, set: { app.setLimitsPopoverShown($0) }),
                 attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: Theme.sidebarRailWidth, height: Theme.footerRowHeight))),
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
                if i > 0 { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).padding(.horizontal, -Theme.Limit.popoverPaddingH) }
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
                    HStack(spacing: Theme.railInset) {
                        IconView(icon: .refresh, size: Theme.smallIconSize, tint: Theme.ui.text3)
                        Text(L10n.refresh)
                    }
                    .padding(.horizontal, Theme.railInset)
                }
                .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                .help(L10n.refreshLimitsHelp)
            }
            .font(.system(size: Theme.fontSize.small))
            .foregroundStyle(Theme.ui.text3)
            .padding(.top, Theme.railInset)
        }
        .padding(.vertical, Theme.Limit.popoverPaddingV)
        .padding(.horizontal, Theme.Limit.popoverPaddingH)
        .frame(width: Theme.Limit.popoverWidth)
        .presentationBackground(Theme.ui.sheet)
    }

    private func agent(_ agent: UsageAgent, _ u: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Limit.itemGap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Limit.rowGap) {
                Text(agentName(agent)).font(.system(size: Theme.Limit.agentFont, weight: .bold)).foregroundStyle(Theme.ui.textStrong)
                if let plan = u.plan { Text(plan).foregroundStyle(Theme.ui.text2) }
                Spacer(minLength: 0)
                Text(L10n.updatedAgo(ageLabel(since: u.updatedAt, now: app.usageClock)))
                    .font(.system(size: Theme.fontSize.small).monospaced())
                    .foregroundStyle(Theme.ui.text3)
            }
            .font(.system(size: Theme.fontSize.small))
            ForEach(u.windows.sorted { rank($0.kind) < rank($1.kind) }, id: \.kind) { w in
                window(w, agent: agent, level: windowLevel(w, in: u))
            }
        }
    }

    private func window(_ w: UsageWindow, agent: UsageAgent, level: UsageLevel) -> some View {
        VStack(alignment: .leading, spacing: Theme.railInset) {
            HStack(spacing: Theme.Limit.rowGap) {
                Text(limitWindowTitle(w.kind, agent: agent)).fontWeight(.medium).foregroundStyle(Theme.ui.text)
                Spacer(minLength: 0)
                if level > .ok {
                    Text(level == .full ? L10n.limitBadgeFull : L10n.limitBadgeAlmost)
                        .font(.system(size: Theme.Limit.badgeFont))
                        .foregroundStyle(Theme.Limit.textColor(level))
                        .padding(.horizontal, Theme.Limit.badgePaddingH)
                        .padding(.vertical, Theme.Limit.badgePaddingV)
                        .background(Capsule().fill(Theme.Limit.color(level).opacity(Theme.Limit.badgeOpacity)))
                }
                Text(percentText(w.usedPercent)).monospacedDigit().foregroundStyle(Theme.ui.text2)
            }
            .font(.system(size: Theme.fontSize.footer))
            LimitBar(percent: w.usedPercent, level: level, height: Theme.Limit.popoverBar)
            if let r = w.resetsAt, r > app.usageClock {
                Text(resetLabel(r, now: app.usageClock, calendar: .current))
                    .font(.system(size: Theme.fontSize.small))
                    .foregroundStyle(Theme.ui.text3)
            }
        }
    }
}
