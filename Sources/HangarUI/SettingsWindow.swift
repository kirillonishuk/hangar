import AppKit
import SwiftUI
import Workspace

/// ⌘, / gear in the sidebar: one card of "label → value" rows (sheet style of new-task-v4), width 520.
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
        if !window.isVisible, let parent {
            let p = parent.frame
            window.setFrameOrigin(NSPoint(x: p.midX - window.frame.width / 2, y: p.maxY - window.frame.height - Theme.settingsTopOffset))
        }
        model.externalEditor = model.app.config.externalEditor ?? ""
        window.makeKeyAndOrderFront(nil)
    }

    /// The external-editor field saves on ↩ / focus loss; closing the window must not drop a typed value.
    func windowWillClose(_ notification: Notification) { model.commitExternalEditor() }
}

/// Settings state shared by the view and its window (draft of the text field, last write error).
@MainActor @Observable final class SettingsModel {
    let app: AppState
    var externalEditor = ""
    var error: String?

    init(app: AppState) { self.app = app }

    func commitExternalEditor() {
        let value = externalEditor.trimmingCharacters(in: .whitespaces)
        guard value != (app.config.externalEditor ?? "") else { return }
        save { try app.setConfig("external_editor", value) { $0.externalEditor = value.isEmpty ? nil : value } }
    }

    func save(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch {
            uiLog.error("config write failed: \(String(describing: error), privacy: .public)")
            self.error = L10n.saveFailed(error.localizedDescription)
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
                    Segment(selection: app.config.editor, options: editorOptions.map { ($0, $0) }) { editor in
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
                        .onSubmit(model.commitExternalEditor)
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
                row(L10n.terminalBackground) {
                    Segment(selection: app.config.terminalBackground, options: [(.hangar, "Hangar"), (.theme, L10n.backgroundTheme)]) { bg in
                        save { try app.setConfig("terminal_background", bg.rawValue) { $0.terminalBackground = bg } }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.ui.lineSheet, lineWidth: 1))

            HStack(spacing: 0) {
                if let error = model.error {
                    Text(error).foregroundStyle(Theme.ui.failed).lineLimit(2)
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
    }

    /// hx / nvim, plus the configured editor when it is something else.
    private var editorOptions: [String] {
        let base = ["hx", "nvim"]
        return base.contains(app.config.editor) ? base : base + [app.config.editor]
    }

    private func save(_ change: () throws -> Void) { model.save(change) }

    private func row(_ label: String, first: Bool = false, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: Theme.cardRowGap) {
            Text(label).foregroundStyle(Theme.ui.text2).frame(width: Theme.settingsLabelWidth, alignment: .leading)
            value()
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).opacity(first ? 0 : 1) }
    }
}

/// Segmented control in the token colors (`field` track, `control` active segment).
private struct Segment<Value: Equatable>: View {
    let selection: Value
    let options: [(Value, String)]
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: Theme.segmentPadding) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let on = value == selection
                Button { if !on { choose(value) } } label: {
                    Text(title)
                        .foregroundStyle(on ? Theme.ui.textStrong : Theme.ui.text2)
                        .padding(.vertical, Theme.segmentItemPaddingV)
                        .padding(.horizontal, Theme.segmentItemPaddingH)
                        .background(RoundedRectangle(cornerRadius: Theme.segmentItemRadius).fill(on ? Theme.ui.control : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand(!on)
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
