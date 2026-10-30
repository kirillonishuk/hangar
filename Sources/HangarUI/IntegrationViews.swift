import ControlServer
import Integration
import SwiftUI

/// A function of an agent's integration (#111): title, a `text3` line under it, an optional tag, then its control.
struct FunctionRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    var subtitleColor = Theme.ui.text3
    var tag: String?
    var tagHelp: String?
    var first = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.cardRowGap) {
            VStack(alignment: .leading, spacing: Theme.integrationSubGap) {
                Text(verbatim: title).font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.text)
                Text(verbatim: subtitle).font(Theme.Typography.secondary.font()).foregroundStyle(subtitleColor)
                    .lineLimit(1).truncationMode(.tail).help(subtitle)
            }
            .layoutPriority(1)
            if let tag { TagPill(text: tag).help(tagHelp ?? "") }
            Spacer(minLength: Theme.cardRowGap)
            trailing
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: Theme.cardRowMinHeight, alignment: .leading)
        .padding(.vertical, Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).opacity(first ? 0 : 1) }
    }
}

/// «этот Mac»: an outlined `text3` tag.
struct TagPill: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.caption.font())
            .foregroundStyle(Theme.ui.text3)
            .padding(.horizontal, Theme.integrationTagPaddingH)
            .frame(height: Theme.integrationTagHeight)
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius).stroke(Theme.ui.control, lineWidth: 1))
            .fixedSize()
    }
}

/// One machine in «Где установлено» / «Куда».
struct WhereItem: Identifiable {
    enum Mark { case check, none, note(String), dot(Color, String), link(String) }
    var id: String
    var icon: Icon
    var name: String
    var mark: Mark
    var help: String
    var action: (() -> Void)?
}

/// The compact line of machines under an agent's card (no per-machine settings: the choice is shared).
struct WhereRow: View {
    let label: String
    let items: [WhereItem]

    var body: some View {
        // Wraps instead of cutting a host's state off when the window is narrow or the hosts are many.
        FlowLayout(spacing: Theme.integrationWhereGap, lineSpacing: Theme.sheetLineGap) {
            Text(verbatim: label).foregroundStyle(Theme.ui.text3)
            ForEach(items) { item in entry(item) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Theme.Typography.secondary.font())
        .lineLimit(1)
        .padding(.vertical, Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1) }
    }

    @ViewBuilder private func entry(_ item: WhereItem) -> some View {
        if let action = item.action {
            Button(action: action) { label(item) }.buttonStyle(.plain).pointingHand()
        } else {
            label(item)
        }
    }

    private func label(_ item: WhereItem) -> some View {
        HStack(spacing: Theme.sheetLineGap + 2) {
            IconView(icon: item.icon, size: Theme.integrationWhereIcon, tint: Theme.ui.text2)
            Text(verbatim: item.name).foregroundStyle(Theme.ui.text)
            mark(item.mark)
        }
        .help(item.help)
    }

    @ViewBuilder private func mark(_ m: WhereItem.Mark) -> some View {
        switch m {
        case .check: IconView(icon: .check, size: Theme.integrationWhereIcon, tint: Theme.ui.done)
        case .none: EmptyView()
        case .note(let t): Text(verbatim: t).foregroundStyle(Theme.ui.text3)
        case .dot(let color, let t):
            Circle().fill(color).frame(width: Theme.statusDot, height: Theme.statusDot)
            Text(verbatim: t).foregroundStyle(Theme.ui.text3)
        case .link(let t):
            Circle().fill(Theme.ui.waiting).frame(width: Theme.statusDot, height: Theme.statusDot)
            Text(verbatim: t).foregroundStyle(Theme.ui.accent)
        }
    }
}

/// Children left to right at their own size, wrapping to a new line when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0, height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, view) in zip(arrange(subviews, width: bounds.width), subviews) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var out: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + lineSpacing; line = 0 }
            out.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return out
    }
}

/// «Что изменится»: each file's exact diff (long lines wrap: everything written is visible).
struct ChangesView: View {
    let changes: [PlannedChange]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sheetLineGap) {
            if changes.isEmpty {
                Text(verbatim: L10n.intNoChanges).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
            }
            let lines = VStack(alignment: .leading, spacing: Theme.sheetLineGap) {
                ForEach(changes) { change in
                    Text(verbatim: change.path)
                        .font(Theme.Typography.monoSmall.font()).foregroundStyle(Theme.ui.text2)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(change.diff.indices, id: \.self) { i in line(change.diff[i]) }
                    }
                    .padding(.vertical, Theme.sheetLineGap)
                    .background(RoundedRectangle(cornerRadius: Theme.fieldRadius).fill(Theme.ui.field))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius).stroke(Theme.ui.control, lineWidth: 1))
                }
            }
            if !changes.isEmpty {
                ViewThatFits(in: .vertical) {
                    lines
                    ScrollView(.vertical) { lines }.frame(height: Theme.Diff.maxHeight)
                }
                .frame(maxHeight: Theme.Diff.maxHeight)
                .font(Theme.Typography.monoSmall.font())
            }
        }
        .lineLimit(nil)
    }

    @ViewBuilder private func line(_ l: DiffLine) -> some View {
        switch l {
        case .same(let t): row(" ", t, marker: Theme.ui.text3, background: .clear)
        case .added(let t): row("+", t, marker: Theme.Diff.addMarker, background: Theme.Diff.add)
        case .removed(let t): row("-", t, marker: Theme.Diff.delMarker, background: Theme.Diff.del)
        case .skipped(let n): row(" ", L10n.linesUnchanged(n), marker: Theme.ui.text3, text: Theme.ui.text3, background: .clear)
        }
    }

    private func row(_ sign: String, _ value: String, marker: Color, text: Color = Theme.ui.text, background: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: sign).foregroundStyle(marker).frame(width: Theme.Diff.markerWidth, alignment: .leading)
            Text(verbatim: value).foregroundStyle(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Diff.paddingH)
        .padding(.vertical, Theme.Diff.linePaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }
}

/// Title row of the integration sheets: an icon, the question; under it what answering means.
private struct AskHeader: View {
    let icon: Icon
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sheetLineGap) {
            HStack(spacing: Theme.sheetButtonGap) {
                IconView(icon: icon, size: Theme.integrationTitleIcon, tint: Theme.ui.text2)
                Text(verbatim: title).font(Theme.Typography.title.font(.semibold)).foregroundStyle(Theme.ui.sheetText)
            }
            Text(verbatim: subtitle).font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.text3)
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.sheetHeaderTop)
        .padding(.bottom, Theme.sheetGap)
    }
}

/// Footer of the integration sheets: «Что изменится» on the left, the answers on the right (Esc = the negative one).
private struct AskFooter: View {
    let shown: Bool
    let skip: String
    let onChanges: () -> Void
    let onAnswer: (Bool) -> Void

    var body: some View {
        HStack(spacing: Theme.sheetButtonGap) {
            Button(shown ? L10n.intHideChanges : L10n.intWhatChanges, action: onChanges)
                .buttonStyle(.plain).foregroundStyle(Theme.ui.accent).pointingHand()
            Spacer(minLength: 0)
            Button(skip) { onAnswer(false) }
                .buttonStyle(SheetButton(primary: false))
                .keyboardShortcut(.cancelAction)
            Button(L10n.intConnect) { onAnswer(true) }
                .buttonStyle(SheetButton(primary: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, Theme.sheetFooterPaddingV)
        .padding(.top, Theme.sheetGap)
    }
}

/// «Подключить Hangar к Claude Code?» (#111): before the agent's first tab starts; the switches are its functions.
struct IntegrationAgentSheet: View {
    let agent: MCPAgent
    /// Read in `body`: a language switch while the sheet is up redraws them.
    let whereItems: () -> [WhereItem]
    let preview: (AgentChoice) async -> [PlannedChange]
    let onAnswer: (Bool, AgentChoice) -> Void
    @State private var choice = AgentChoice()
    @State private var changes: [PlannedChange]?
    /// Set by the debug channel: a click on a button.
    var expose: ((@escaping (Bool) -> Void, @escaping () -> Void) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskHeader(icon: agent == .claude ? .claude : .codex, title: L10n.intSheetTitle(agentTitle(agent)), subtitle: L10n.intSheetSubtitle)
            VStack(spacing: 0) {
                FunctionRow(title: L10n.intHooksTitle, subtitle: agent == .claude ? L10n.intHooksClaudeSub : L10n.intHooksCodexSub, first: true) {
                    CardSwitch(on: choice.hooks) { choice.hooks = $0; refresh() }
                }
                if agent == .claude {
                    FunctionRow(title: L10n.intLimitsTitle, subtitle: L10n.intLimitsSub) {
                        CardSwitch(on: choice.limits) { choice.limits = $0; refresh() }
                    }
                    FunctionRow(title: L10n.intStatuslineSheetTitle, subtitle: L10n.intStatuslineSheetSub) {
                        CardSwitch(on: choice.statusline) { choice.statusline = $0; refresh() }
                    }
                }
                FunctionRow(title: L10n.integrationMCP, subtitle: L10n.intMCPSheetSub, tag: L10n.intThisMacTag, tagHelp: L10n.intThisMacTagHelp) {
                    CardSwitch(on: choice.mcp) { choice.mcp = $0; refresh() }
                }
                WhereRow(label: L10n.intWhereTo, items: whereItems())
            }
            .sheetCard()
            if let changes { ChangesView(changes: changes).padding(.top, Theme.sheetGap) }
            AskFooter(shown: changes != nil, skip: L10n.intNotNow, onChanges: toggleChanges) { onAnswer($0, choice) }
        }
        .sheetFrame()
        .onAppear { expose?({ onAnswer($0, choice) }, toggleChanges) }
    }

    private func toggleChanges() {
        if changes != nil { changes = nil } else { refresh(force: true) }
    }

    private func refresh(force: Bool = false) {
        guard force || changes != nil else { return }
        let c = choice
        Task { changes = await preview(c) }
    }
}

/// «Подключить Hangar на <host>?» (#111): the shared choice, listed; no switches.
struct IntegrationHostSheet: View {
    let host: String
    /// The connected agents and their functions as a phrase (read in `body`, like the agent sheet's machines).
    let parts: () -> [(agent: MCPAgent, text: String)]
    let preview: () async -> [PlannedChange]
    let onAnswer: (Bool) -> Void
    @State private var changes: [PlannedChange]?
    var expose: ((@escaping (Bool) -> Void, @escaping () -> Void) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskHeader(icon: .sshHost, title: L10n.intHostTitle(host), subtitle: L10n.intHostSubtitle)
            VStack(spacing: 0) {
                let parts = parts()
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    line(icon: p.agent == .claude ? .claude : .codex, title: agentTitle(p.agent), detail: p.text, first: i == 0)
                }
                line(icon: .shell, title: "hangar-remote \(hangarRemoteVersion)", detail: L10n.intHostRemote, first: parts.isEmpty)
            }
            .sheetCard()
            if let changes { ChangesView(changes: changes).padding(.top, Theme.sheetGap) }
            AskFooter(shown: changes != nil, skip: L10n.intHostSkip, onChanges: toggleChanges, onAnswer: onAnswer)
        }
        .sheetFrame()
        .onAppear { expose?(onAnswer, toggleChanges) }
    }

    private func toggleChanges() {
        if changes != nil { changes = nil; return }
        Task { changes = await preview() }
    }

    private func line(icon: Icon, title: String, detail: String, first: Bool) -> some View {
        HStack(spacing: Theme.sheetButtonGap) {
            IconView(icon: icon, size: Theme.integrationTitleIcon, tint: Theme.ui.text2)
            Text(verbatim: title).foregroundStyle(Theme.ui.text)
            Spacer(minLength: Theme.cardRowGap)
            Text(verbatim: detail).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.cardRowMinHeight, alignment: .leading)
        .padding(.vertical, Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).opacity(first ? 0 : 1) }
    }
}

@MainActor func agentTitle(_ agent: MCPAgent) -> String { agent == .claude ? L10n.integrationClaude : L10n.integrationCodex }
