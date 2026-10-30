import Integration
import SwiftUI
import Workspace

/// Settings → Интеграции (#111): one card per agent, grouped by function; every switch applies everywhere (this Mac and
/// every agreed host); «Где установлено» shows where. No per-machine settings, no install buttons.
extension SettingsView {
    var integrations: some View {
        VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
            if let notice = integrationNotice {
                Text(verbatim: notice).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.waiting)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
            agentCard(.claude)
            agentCard(.codex)
        }
    }

    /// Nothing can be written: no bundled helper (DEBUG `swift run`), or the app runs from a DMG / translocated.
    private var integrationNotice: String? {
        guard let cli = app.integrationCLI else { return L10n.integrationNeedsApp }
        return installBlocked(cli: cli) ? L10n.moveToApplications : nil
    }

    @ViewBuilder private func agentCard(_ agent: MCPAgent) -> some View {
        let found = app.integrations.agentCLI[agent]
        // Main switch: off = none of the agent's functions anywhere; undecided reads as off until answered.
        let on = app.config.integration(agent) == true
        VStack(alignment: .leading, spacing: Theme.settingsHeaderGap) {
            HStack(spacing: Theme.sheetButtonGap) {
                IconView(icon: agent == .claude ? .claude : .codex, size: Theme.integrationTitleIcon)
                Text(verbatim: agentTitle(agent))
                    .font(.system(size: Theme.integrationAgentTitle, weight: .semibold)).foregroundStyle(Theme.ui.textStrong)
                Spacer(minLength: 0)
                if found != .some(nil) {
                    CardSwitch(on: on) { v in
                        app.setIntegration(agent, key: agent == .claude ? "claude_integration" : "codex_integration", on: v) {
                            if agent == .claude { $0.claudeIntegration = v } else { $0.codexIntegration = v }
                        }
                    }
                    .help(L10n.intAgentOffHelp)
                }
            }
            VStack(spacing: 0) {
                if found == .some(nil) {
                    notFoundRow(agent)
                } else {
                    VStack(spacing: 0) { functionRows(agent) }
                        .opacity(on ? 1 : Theme.inactiveOpacity)
                        .disabled(!on)
                    mcpRow(agent)
                    WhereRow(label: L10n.intWhereInstalled, items: whereItems(agent))
                        .opacity(on ? 1 : Theme.inactiveOpacity)
                }
            }
            .sheetCard()
        }
    }

    @ViewBuilder private func functionRows(_ agent: MCPAgent) -> some View {
        switch agent {
        case .claude:
            FunctionRow(title: L10n.intHooksTitle, subtitle: L10n.intHooksClaudeSub, first: true) {
                flag(.claude, "claude_hooks", app.config.claudeHooks) { c, v in c.claudeHooks = v }
            }
            FunctionRow(title: L10n.intLimitsTitle, subtitle: L10n.intLimitsSub) {
                flag(.claude, "claude_limits", app.config.claudeLimits) { c, v in c.claudeLimits = v }
            }
            statuslineRows
        case .codex:
            FunctionRow(title: L10n.intHooksTitle, subtitle: L10n.intHooksCodexSub, first: true) {
                flag(.codex, "codex_notify", app.config.codexNotify) { c, v in c.codexNotify = v }
            }
        }
    }

    private func flag(_ agent: MCPAgent, _ key: String, _ value: Bool, _ apply: @escaping (inout HangarConfig, Bool) -> Void) -> some View {
        CardSwitch(on: value) { v in app.setIntegration(agent, key: key, on: v) { apply(&$0, v) } }
    }

    private func mcpRow(_ agent: MCPAgent) -> some View {
        let (text, color) = mcpLine(agent)
        let usable: Bool = switch app.integrations.mcp[agent] {
        case .unavailable?, .noCLI?: false
        default: true
        }
        return FunctionRow(title: L10n.integrationMCP, subtitle: text, subtitleColor: color, tag: L10n.intThisMacTag, tagHelp: L10n.intThisMacTagHelp) {
            CardSwitch(on: app.config.mcp(agent)) { app.setMCP(agent, on: $0) }
                .disabled(!usable)
                .help(L10n.intMCPNote)
        }
    }

    private func mcpLine(_ agent: MCPAgent) -> (String, Color) {
        let on = app.config.mcp(agent)
        switch app.integrations.mcp[agent] ?? .checking {
        case .checking: return (L10n.integrationChecking, Theme.ui.text3)
        case .unavailable: return (L10n.intMCPSub, Theme.ui.text3)
        case .noCLI: return (L10n.intTipNoAgent(agent.rawValue), Theme.ui.text3)
        case .failed(let why): return (L10n.intMCPFailed(why), Theme.ui.failedText)
        case .entry(let e):
            switch e {
            case .foreign: return (L10n.intMCPForeign, Theme.ui.waiting)
            case .otherCopy: return (L10n.intMCPOtherCopy, Theme.ui.text3)
            case .unreadable: return (L10n.intMCPUnreadable, Theme.ui.waiting)
            case .absent where on: return (L10n.intMCPMissing, Theme.ui.waiting)
            default: return (L10n.intMCPSub, Theme.ui.text3)
            }
        }
    }

    private func notFoundRow(_ agent: MCPAgent) -> some View {
        HStack(spacing: Theme.cardRowGap) {
            Pill(text: L10n.intNotFound, color: Theme.ui.text3)
            Text(verbatim: L10n.intAgentNotFound(agent.rawValue, agentTitle(agent)))
                .font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.cardRowMinHeight, alignment: .leading)
        .padding(.vertical, Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
    }

    /// This Mac and every host (with projects or decided): ✓, «нет связи», «codex нет», «Подключить…», an error.
    private func whereItems(_ agent: MCPAgent) -> [WhereItem] {
        let mac = app.integrations.marks[agent]?[IntegrationStatus.mac]
        var items = [item(agent, id: "mac", icon: .mac, name: L10n.intThisMac, mark: mac ?? .done(changed: nil, backup: nil), host: nil)]
        for host in app.integrationHostList {
            items.append(item(agent, id: host, icon: .sshHost, name: host, mark: app.hostMark(agent, host), host: host))
        }
        return items
    }

    private func item(_ agent: MCPAgent, id: String, icon: Icon, name: String, mark: MachineMark, host: String?) -> WhereItem {
        let retry: () -> Void = { [app] in Task { await app.reapply(agent) } }
        switch mark {
        case .done(let changed, let backup):
            var help = changed.map { L10n.intTipUpdated($0.formatted(date: .abbreviated, time: .shortened)) } ?? L10n.intTipCurrent
            if let backup { help += "\n" + L10n.intTipBackup(backup) }
            return WhereItem(id: id, icon: icon, name: name, mark: .check, help: help)
        case .offline:
            return WhereItem(id: id, icon: icon, name: name, mark: .dot(Theme.ui.text3, L10n.intOffline), help: L10n.intTipOffline)
        case .undecided:
            return WhereItem(id: id, icon: icon, name: name, mark: .link(L10n.intConnectEllipsis), help: L10n.intTipUndecided,
                             action: { [app] in if let host { app.askHost(host) } })
        case .skipped:
            return WhereItem(id: id, icon: icon, name: name, mark: .note(L10n.intSkipped), help: L10n.intTipSkipped,
                             action: { [app] in if let host { app.askHost(host) } })
        case .noAgent:
            return WhereItem(id: id, icon: icon, name: name, mark: .note(L10n.intNoAgentOnHost(agent.rawValue)), help: L10n.intTipNoAgent(agent.rawValue))
        case .failed(let why):
            return WhereItem(id: id, icon: icon, name: name, mark: .dot(Theme.ui.failed, L10n.intFailed), help: L10n.intTipFailed(why), action: retry)
        }
    }
}
