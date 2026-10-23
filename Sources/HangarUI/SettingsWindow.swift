import AppKit
import Integration
import SwiftUI
import Workspace

/// ⌘, / gear in the sidebar: one card of "label → value" rows (sheet style of new-task-v4), width 580.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(app: AppState) {
        model = SettingsModel(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.settingsWidth, height: Theme.settingsPlaceholderHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.sheet
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        super.init(window: window)
        window.delegate = self
        updateTitle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func updateTitle() { window?.title = L10n.settings }

    func present(over parent: NSWindow?) {
        guard let window else { return }
        // Already open (⌘, again): only bring it forward, keep the typed draft.
        if !window.isVisible {
            if let parent {
                let p = parent.frame
                window.setFrameOrigin(NSPoint(x: p.midX - window.frame.width / 2, y: p.maxY - window.frame.height - Theme.settingsTopOffset))
            }
            model.externalEditor = model.app.config.externalEditor ?? ""
        }
        let integration = model.integration
        Task { await integration.refresh() }
        window.makeKeyAndOrderFront(nil)
    }

    /// The external-editor field saves on ↩ / focus loss; closing the window must not drop a typed value.
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.shouldClose() }

    /// Closes that skip `windowShouldClose` (app quit) still save the draft.
    func windowWillClose(_ notification: Notification) { model.commitExternalEditor() }
}

/// Settings state shared by the view and its window (draft of the text field, last write error).
@MainActor @Observable final class SettingsModel {
    let app: AppState
    var externalEditor = ""
    var error: String?
    /// The draft whose save failed on close (the user has seen the error).
    private var refusedDraft: String?
    let integration: IntegrationModel
    /// Shown in the consent sheet; nothing is written until it is confirmed.
    var pendingPlan: IntegrationPlan?

    init(app: AppState) {
        self.app = app
        integration = IntegrationModel(claudeSettings: app.claudeSettingsURL, codexConfig: app.codexConfigURL,
                                       cli: hangarCLIPath(bundle: .main), findCodex: app.findCodex, findDirs: app.findAgentDirs)
    }

    func review(_ target: IntegrationTarget, install: Bool) {
        integration.message = nil
        integration.error = nil
        pendingPlan = integration.plan(target, install: install)
    }

    func confirmPlan() {
        guard let plan = pendingPlan else { return }
        pendingPlan = integration.confirm(plan)
    }

    func cancelPlan() {
        pendingPlan = nil
        integration.error = nil
    }

    func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        error = nil
        integration.message = L10n.commandCopied
    }

    /// False when saving the draft fails: the window stays open with the error; closing again with the same draft closes.
    func shouldClose() -> Bool {
        if commitExternalEditor() { refusedDraft = nil; return true }
        defer { refusedDraft = externalEditor }
        return refusedDraft == externalEditor
    }

    @discardableResult func commitExternalEditor() -> Bool {
        let value = externalEditor.trimmingCharacters(in: .whitespaces)
        guard value != (app.config.externalEditor ?? "") else { return true }
        return save { try app.setConfig("external_editor", value) { $0.externalEditor = value.isEmpty ? nil : value } }
    }

    @discardableResult func save(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            error = nil
            return true
        } catch {
            uiLog.error("config write failed: \(String(describing: error), privacy: .public)")
            self.error = L10n.saveFailed(error.localizedDescription)
            return false
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    private var app: AppState { model.app }
    @FocusState private var editingExternal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                row(L10n.languageTitle, first: true) {
                    Segment(selection: app.language, options: [
                        (.system, L10n.languageSystem), (.ru, L10n.languageRu), (.en, L10n.languageEn),
                    ]) { lang in save { try app.setLanguage(lang) } }
                }
                row(L10n.defaultAgent) {
                    Segment(selection: app.config.defaultAgent, options: [(.claude, "claude"), (.codex, "codex")]) { kind in
                        save { try app.setConfig("default_agent", kind.rawValue) { $0.defaultAgent = kind } }
                    }
                }
                row(L10n.editor) {
                    Segment(selection: app.config.editor, options: editorOptions.map { ($0, ($0 as NSString).lastPathComponent) }) { editor in
                        save { try app.setConfig("editor", editor) { $0.editor = editor } }
                    }
                    .font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                }
                row(L10n.externalEditor) {
                    TextField("", text: $model.externalEditor,
                              prompt: Text(L10n.externalEditorPlaceholder).foregroundStyle(Theme.ui.text3))
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                        .foregroundStyle(Theme.ui.sheetText)
                        .focused($editingExternal)
                        .onSubmit { model.commitExternalEditor() }
                        .onChange(of: editingExternal) { _, focused in if !focused { model.commitExternalEditor() } }
                }
                row(L10n.notificationsTitle) {
                    Segment(selection: app.config.notifications, options: [(true, L10n.toggleOn), (false, L10n.toggleOff)]) { on in
                        save { try app.setConfig("notifications", flag: on) { $0.notifications = on } }
                    }
                }
                row(L10n.limitNotificationsTitle) {
                    Segment(selection: app.config.limitNotifications, options: [(true, L10n.toggleOn), (false, L10n.toggleOff)]) { on in
                        save { try app.setConfig("limit_notifications", flag: on) { $0.limitNotifications = on } }
                    }
                }
                row(L10n.keepAwakeTitle) {
                    Segment(selection: app.config.keepAwake, options: [(true, L10n.toggleOn), (false, L10n.toggleOff)]) { on in
                        save { try app.setConfig("keep_awake", flag: on) { $0.keepAwake = on } }
                    }
                }
                row(L10n.integrationClaude) { integrationValue(.claude) }
                row(L10n.integrationCodex) { integrationValue(.codex) }
                row(L10n.integrationMCP) { mcpValue }
                row(L10n.terminalBackground) {
                    Segment(selection: app.config.terminalBackground, options: [(.hangar, "Hangar"), (.theme, L10n.backgroundTheme)]) { bg in
                        save { try app.setConfig("terminal_background", bg.rawValue) { $0.terminalBackground = bg } }
                    }
                }
            }
            .sheetCard()

            HStack(spacing: 0) {
                if let error = model.error {
                    Text(verbatim: error).foregroundStyle(Theme.ui.failed).lineLimit(2)
                } else if let message = model.integration.message {
                    Text(verbatim: message).foregroundStyle(Theme.ui.text2).lineLimit(2)
                } else if app.config.terminalBackground != app.launchTerminalBackground {
                    // Ghostty reads its background once at start.
                    Text(L10n.afterRestart).foregroundStyle(Theme.ui.text3)
                } else {
                    Text(app.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: Theme.fontSize.tab, design: .monospaced))
                        .foregroundStyle(Theme.ui.text3)
                }
            }
            .font(.system(size: Theme.fontSize.tab))
            .padding(.vertical, Theme.sheetFooterPaddingV)
        }
        .padding(.top, Theme.sheetGap)
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.settingsWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .background(Theme.ui.sheet)
        .sheet(isPresented: Binding(get: { model.pendingPlan != nil }, set: { if !$0 { model.cancelPlan() } })) {
            if let plan = model.pendingPlan {
                IntegrationSheet(plan: plan, error: model.integration.error, onApply: model.confirmPlan, onCancel: model.cancelPlan)
            }
        }
    }

    /// State of one integration and the action that changes it (only after the consent sheet).
    @ViewBuilder private func integrationValue(_ target: IntegrationTarget) -> some View {
        let status = integrationStatus(target)
        let integration = model.integration
        HStack(spacing: Theme.cardRowGap) {
            VStack(alignment: .leading, spacing: Theme.sheetLineGap) {
                Text(verbatim: status.text)
                    .foregroundStyle(status.color)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if model.pendingPlan == nil, integration.errorTarget == target, let error = integration.error {
                    Text(verbatim: error).foregroundStyle(Theme.ui.failed).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if integration.pathsReady, integration.cli != nil, target == .claude || integration.codex != .notFound {
                    Text(verbatim: tildePath((target == .claude ? integration.claudeSettings : integration.codexConfig).path))
                        .font(.system(size: Theme.fontSize.counter, design: .monospaced))
                        .foregroundStyle(Theme.ui.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let action = status.action {
                Button(action.title) { model.review(target, install: action.install) }
                    .buttonStyle(SheetButton(primary: false))
                    .fixedSize()
            }
        }
    }

    /// Commands for the user to run in a terminal: Hangar itself never touches the agents' MCP configs.
    @ViewBuilder private var mcpValue: some View {
        if let cli = model.integration.cli {
            let commands = mcpAddCommands(cli: cli)
            VStack(alignment: .leading, spacing: Theme.sheetLineGap) {
                ForEach([commands.claude, commands.codex], id: \.self) { command in
                    HStack(alignment: .top, spacing: Theme.cardRowGap) {
                        Text(verbatim: command)
                            .font(.system(size: Theme.fontSize.counter, design: .monospaced))
                            .foregroundStyle(Theme.ui.text2)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button(L10n.copyCommand) { model.copy(command) }
                            .buttonStyle(SheetButton(primary: false))
                            .fixedSize()
                    }
                }
                Text(L10n.mcpHint).foregroundStyle(Theme.ui.text3)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // A message, not a label: wraps like the integration rows' status instead of truncating.
            Text(L10n.integrationNeedsApp).foregroundStyle(Theme.ui.text3)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func integrationStatus(_ target: IntegrationTarget) -> (text: String, color: Color, action: (title: String, install: Bool)?) {
        let integration = model.integration
        guard integration.pathsReady else { return (L10n.integrationChecking, Theme.ui.text3, nil) }
        let state: IntegrationState
        switch target {
        case .claude: state = integration.claude
        case .codex:
            switch integration.codex {
            case nil: return (L10n.codexLookup, Theme.ui.text3, nil)
            case .notFound?: return (L10n.codexNotFound, Theme.ui.text3, nil)
            case .found(let s)?: state = s
            }
        }
        guard let cli = integration.cli else { return (L10n.integrationNeedsApp, Theme.ui.text3, nil) }
        if installBlocked(cli: cli), state == .notInstalled || state == .outdated {
            return (L10n.moveToApplications, Theme.ui.waiting, nil)  // removal stays possible from the other states
        }
        return switch state {
        case .installed: (L10n.integrationInstalled, Theme.ui.text2, (L10n.removeIntegration, false))
        case .installedStatuslineByUser: (L10n.integrationStatuslineByUser, Theme.ui.text2, (L10n.removeIntegration, false))
        case .outdated: (L10n.integrationOutdated, Theme.ui.waiting, (L10n.updateEllipsis, true))
        case .notInstalled: (target == .claude ? L10n.hooksMissing : L10n.codexNotifyMissing, Theme.ui.failed, (L10n.installEllipsis, true))
        }
    }

    /// hx / nvim, plus the configured editor when it is something else.
    private var editorOptions: [String] {
        let base = ["hx", "nvim"]
        return base.contains(app.config.editor) ? base : base + [app.config.editor]
    }

    private func save(_ change: () throws -> Void) { model.save(change) }

    private func row(_ label: String, first: Bool = false, @ViewBuilder value: () -> some View) -> some View {
        CardRow(label: label, labelWidth: Theme.settingsCardLabelWidth, first: first, value: value)
    }
}

/// Segmented control in the token colors (`field` track, `control` active segment).
private struct Segment<Value: Equatable>: View {
    let selection: Value
    let options: [(Value, String)]
    let choose: (Value) -> Void
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: Theme.segmentPadding) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let on = value == selection
                Button { if !on { choose(value) } } label: {
                    Text(title)
                        .foregroundStyle(on ? Theme.ui.textStrong : hovered == i ? Theme.ui.text : Theme.ui.text2)
                        .padding(.vertical, Theme.segmentItemPaddingV)
                        .padding(.horizontal, Theme.segmentItemPaddingH)
                        .background(RoundedRectangle(cornerRadius: Theme.segmentItemRadius)
                            .fill(on ? Theme.ui.control : hovered == i ? Theme.ui.hover : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand(!on)
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hovered = h ? i : (hovered == i ? nil : hovered) } }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Theme.segmentPadding)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: Theme.segmentRadius).fill(Theme.ui.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.segmentRadius).stroke(Theme.ui.control, lineWidth: 1))
        .animation(Motion.ease(Theme.selectionFade), value: options.firstIndex { $0.0 == selection })
    }
}
