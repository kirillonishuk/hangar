import ControlServer
import Exec
import GhosttyBridge
import Integration
import SwiftUI

/// «Сервер <host>» (580): the check report, the install plan with its exact
/// commands and, after «Установить», the install terminal. Opened from the host row; embedded in «Удалённый проект».
struct ServerCheckSheet: View {
    @Bindable var model: ServerCheckModel
    /// The window's content height: the sheet stays inside it.
    let windowHeight: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.serverTitle(model.host))
            ServerCheckView(model: model, embedded: false, maxHeight: windowHeight - Theme.serverSheetChrome)
                .padding(.top, Theme.sheetNameTop)
            // Esc goes to the install terminal while it runs: the hint would promise a cancel that isn't there.
            SheetFooter(hintHidden: model.phase == .installing) {
                // A running install (maybe at a sudo prompt) is not killed by a stray click.
                Button(model.installRun > 0 ? L10n.close : L10n.cancel, action: onClose)
                    .buttonStyle(SheetButton(primary: false))
                    .disabled(model.phase == .installing)
                    .opacity(model.phase == .installing ? Theme.Opacity.inactive : 1)
                    // Esc belongs to the install terminal while it runs.
                    .keyboardShortcut(model.phase == .installing ? nil : .cancelAction)
                if case .failed = model.phase, model.report == nil {
                    // The check itself failed (host offline): a disabled «Установить» left nothing to do but close.
                    Button(L10n.retry) { Task { await model.refresh() } }
                        .buttonStyle(SheetButton(primary: true))
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    InstallButton(model: model, primary: true)
                }
            }
        }
        .sheetFrame()
    }
}

/// «Установить»: confirms exactly the commands shown above it; the label keeps its width under the spinner.
struct InstallButton: View {
    let model: ServerCheckModel
    let primary: Bool

    var body: some View {
        let busy = model.phase == .installing || model.phase == .checking
        let enabled = model.phase == .ready && !model.plan.steps.isEmpty
        Button(action: model.startInstall) {
            Text(L10n.install).opacity(busy && model.installRun > 0 ? 0 : 1)
                .overlay { if busy && model.installRun > 0 { ProgressView().controlSize(.small) } }
        }
        .buttonStyle(SheetButton(primary: primary))
        .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(!enabled)
        .opacity(enabled || busy ? 1 : Theme.Opacity.inactive)
    }
}

/// The report part, shared by both sheets; `embedded`: «Установить» sits in the plan block (the footer is the owner's).
struct ServerCheckView: View {
    @Bindable var model: ServerCheckModel
    let embedded: Bool
    /// Height this view may take in its sheet (the window's height minus the sheet's own parts).
    let maxHeight: CGFloat
    /// The report's own height, measured: the scroll area is exactly that tall up to the limit.
    @State private var reportHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .checking where model.report == nil:
                HStack(spacing: Theme.pickGap) {
                    ProgressView().controlSize(.small)
                    Text(L10n.integrationChecking).foregroundStyle(Theme.ui.text3)
                }
            case .failed(let message) where model.report == nil:
                errorText(message)
            default:
                if let report = model.report { content(report) }
            }
        }
    }

    @ViewBuilder private func content(_ r: ServerReport) -> some View {
        let report = VStack(alignment: .leading, spacing: 0) {
            tools(r)
            warnings(r)
            planBlock.padding(.top, Theme.sheetGap)
            if case .failed(let message) = model.phase { errorText(message).padding(.top, Theme.sheetMessageTop) }
        }
        // The sheet never outgrows its window: past the budget the report scrolls (the terminal keeps its size).
        let limit = max(Theme.serverReportMinHeight,
                        maxHeight - (model.installSpec == nil ? 0 : Theme.installTerminalHeight + Theme.sheetGap))
        ScrollView(.vertical) {
            report.background(GeometryReader { g in Color.clear.preference(key: ReportHeight.self, value: g.size.height) })
        }
        .frame(height: min(reportHeight, limit))
        .scrollDisabled(reportHeight <= limit)
        .onPreferenceChange(ReportHeight.self) { reportHeight = $0 }
        if let spec = model.installSpec {
            InstallTerminal(spec: spec) { code in Task { await model.installFinished(code: code) } }
                .id(model.installRun)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.installTerminalHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius).stroke(Theme.ui.line2, lineWidth: 1))
                .padding(.top, Theme.sheetGap)
        }
    }

    // MARK: Tools

    /// A found tool: its version (or path) in `text2`, cut in the middle with the whole in the tooltip.
    private func found(_ text: String) -> some View {
        Text(verbatim: L10n.toolFound(text)).foregroundStyle(Theme.ui.text2)
            .lineLimit(1).truncationMode(.middle)
            .help(text)
    }

    private func tools(_ r: ServerReport) -> some View {
        CardSection(title: L10n.sectionToolsTitle) {
            ForEach(Array([RemoteTool.git, .tmux, .claude, .codex].enumerated()), id: \.offset) { i, tool in
                CardRow(label: tool.rawValue, mono: true, compact: true, first: i == 0) {
                    if let info = r.tools[tool] {
                        found(info.version.isEmpty ? info.path : info.version)
                    } else if r.missingRequired.contains(tool) {
                        Pill(text: L10n.toolMissing, color: Theme.ui.failed)
                    } else {
                        Pill(text: L10n.toolOptional, color: Theme.ui.text3)
                    }
                }
            }
            // socat is not a RemoteTool: python3, socat or nc, whichever the check found first.
            CardRow(label: L10n.socketClient, compact: true) {
                if let client = r.socketClient {
                    found(client)
                } else {
                    Pill(text: L10n.toolMissing, color: Theme.ui.failed)
                }
            }
            CardRow(label: "hangar-remote", mono: true, compact: true) {
                if let v = r.remoteVersion, !r.remoteOutdated(current: hangarRemoteVersion) {
                    found(String(v))
                } else if let v = r.remoteVersion {
                    Pill(text: L10n.toolOutdated(String(v)), color: Theme.ui.waiting)
                } else {
                    Pill(text: L10n.toolMissing, color: Theme.ui.failed)
                }
            }
        }
    }

    // MARK: Warnings, plan

    @ViewBuilder private func warnings(_ r: ServerReport) -> some View {
        let lines = (r.socketClient == nil ? [L10n.noStatusClient] : []) + (model.forwarding ? [] : [L10n.forwardFailed])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Theme.sheetLineGap) {
                ForEach(lines, id: \.self) { Text($0).foregroundStyle(Theme.ui.waiting) }
            }
            .font(Theme.Typography.secondary.font())
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.sheetMessageTop)
        }
    }

    private var planBlock: some View {
        VStack(alignment: .leading, spacing: Theme.sheetMessageTop) {
            HStack(spacing: Theme.sheetButtonGap) {
                Text(L10n.installPlanTitle)
                    .font(Theme.Typography.secondary.font(.semibold))
                    .foregroundStyle(Theme.ui.text2)
                Spacer(minLength: 0)
                if embedded, !model.plan.steps.isEmpty { InstallButton(model: model, primary: false) }
            }
            if model.plan.steps.isEmpty && model.plan.manual.isEmpty {
                Text(L10n.allInstalled).foregroundStyle(Theme.ui.text3)
            }
            if !model.missingOptional.isEmpty { optionalTools }
            if !model.plan.steps.isEmpty {
                // Verbatim: exactly what the terminal (and the stdin write) will run.
                VStack(alignment: .leading, spacing: Theme.planCommandGap) {
                    // By title, not index: the plan shrinks after an install while the old rows are still diffed.
                    ForEach(model.plan.steps, id: \.title) { step in
                        Text(verbatim: step.command)
                            .font(Theme.Typography.monoSmall.font())
                            .foregroundStyle(Theme.ui.text2)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, Theme.planPaddingV)
                .padding(.horizontal, Theme.fieldPaddingH)
                .background(RoundedRectangle(cornerRadius: Theme.fieldRadius).fill(Theme.ui.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius).stroke(Theme.ui.line2, lineWidth: 1))
            }
            if !model.plan.manual.isEmpty {
                Text(verbatim: L10n.installManual(model.plan.manual.map(\.rawValue).joined(separator: ", ")))
                    .foregroundStyle(Theme.ui.text3)
            }
            if model.plan.steps.contains(where: { $0.inTerminal && $0.command.contains("sudo ") }) {
                Text(L10n.sudoHint).foregroundStyle(Theme.ui.text3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// «Необязательно: ☐ codex» — unticked by default; a ticked tool joins the commands shown above «Установить».
    private var optionalTools: some View {
        HStack(spacing: Theme.sheetButtonGap) {
            Text(L10n.optionalToolsLabel).foregroundStyle(Theme.ui.text3)
            ForEach(model.missingOptional, id: \.self) { tool in
                HStack(spacing: Theme.inlineGap) {
                    CardSwitch(isOn: Binding(get: { model.optional.contains(tool) },
                                             set: { if $0 { model.optional.insert(tool) } else { model.optional.remove(tool) } }))
                    Text(verbatim: tool.rawValue).font(Theme.Typography.mono.font())
                        .foregroundStyle(Theme.ui.text0)
                }
                .disabled(model.phase == .installing)
            }
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.Typography.mono.font())
            .foregroundStyle(Theme.ui.failed)
            .lineLimit(Theme.errorMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The install terminal in the sheet: one Ghostty surface per run, focused so a sudo password goes straight in.
struct InstallTerminal: NSViewRepresentable {
    let spec: LaunchSpec
    let onExit: (Int32) -> Void

    func makeNSView(context: Context) -> TerminalSurfaceView {
        let view = TerminalSurfaceView(spec: spec)
        view.onChildExit = onExit
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: TerminalSurfaceView, context: Context) {}
}

private struct ReportHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
