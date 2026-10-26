import AppKit
import Integration
import SwiftUI
import Workspace

/// A page of the settings window, in the order of its list.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, editor, notifications, integrations, advanced

    var id: Self { self }

    var titleKey: L10n.Key {
        switch self {
        case .general: .settingsGeneral
        case .appearance: .appearance
        case .editor: .editor
        case .notifications: .settingsNotifications
        case .integrations: .settingsIntegrations
        case .advanced: .settingsAdvanced
        }
    }

    @MainActor var title: String { L10n.s(titleKey) }

    var icon: Icon {
        switch self {
        case .general: .settings
        case .appearance: .appearance
        case .editor: .editor
        case .notifications: .bell
        case .integrations: .plug
        case .advanced: .more
        }
    }

    /// The row labels of the page: the label column is measured from them.
    var labelKeys: [L10n.Key] {
        switch self {
        case .general: [.languageTitle, .defaultAgent, .externalEditor]
        case .appearance: [.terminalBackground]
        case .editor: [.editorPaletteTitle, .editorRainbowTitle, .editorTodoTitle]
        case .notifications: [.notificationsTitle, .limitNotificationsTitle, .dockBadgeTitle, .keepAwakeShort]
        case .integrations: [.integrationClaude, .integrationCodex, .integrationMCP]
        case .advanced: [.configFile]
        }
    }
}

/// One-line width of a row label at `sheetRow`.
func settingsLabelTextWidth(_ label: String) -> CGFloat {
    ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Theme.fontSize.sheetRow)]).width)
}

/// The label column of every page: the longest label of the language, so labels never wrap and all cards line up.
func settingsLabelWidth(_ lang: Language) -> CGFloat {
    let widest = SettingsCategory.allCases.flatMap(\.labelKeys)
        .map { settingsLabelTextWidth(L10n.lookup($0, lang, in: L10n.resources)) }.max() ?? 0
    return min(widest + Theme.settingsLabelSlack, Theme.settingsLabelMax)
}

/// Settings integration pill: green when installed, amber for a to-do; red is kept for errors.
@MainActor func integrationPill(_ state: IntegrationState) -> (text: String, color: Color) {
    switch state {
    case .installed, .installedStatuslineByUser: (L10n.pillInstalled, Theme.ui.done)
    case .outdated: (L10n.pillOutdated, Theme.ui.waiting)
    case .notInstalled: (L10n.pillMissing, Theme.ui.waiting)
    }
}

/// An integration's status color in the server sheet: red is kept for failures, a missing or outdated one is a to-do.
@MainActor func integrationStatusColor(_ state: IntegrationState) -> Color {
    switch state {
    case .installed, .installedStatuslineByUser: Theme.ui.text2
    case .outdated, .notInstalled: Theme.ui.waiting
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    private var app: AppState { model.app }
    @FocusState private var editingExternal: Bool

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $model.category)
            Rectangle().fill(Theme.ui.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
                        Text(verbatim: model.category.title)
                            .font(.system(size: Theme.settingsPageTitle, weight: .semibold))
                            .foregroundStyle(Theme.ui.textStrong)
                        page
                    }
                    .padding(Theme.settingsPagePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .frame(minWidth: Theme.settingsMinSize.width, minHeight: Theme.settingsMinSize.height)
        .font(.system(size: Theme.fontSize.sheetRow))
        .background(Theme.ui.sheet)
        .sheet(isPresented: Binding(get: { model.pendingPlan != nil }, set: { if !$0 { model.cancelPlan() } })) {
            if let plan = model.pendingPlan {
                IntegrationSheet(plan: plan, error: model.integration.error, onApply: model.confirmPlan, onCancel: model.cancelPlan)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch model.category {
        case .general: general
        case .appearance: appearance
        case .editor: editor
        case .notifications: notifications
        case .integrations: integrations
        case .advanced: advanced
        }
    }

    /// A write error or an integration message, under the page (nothing when all is well: no jump of the cards).
    @ViewBuilder private var footer: some View {
        if let text = model.error ?? model.integration.message {
            Text(verbatim: text)
                .foregroundStyle(model.error != nil ? Theme.ui.failedText : Theme.ui.text2)
                .lineLimit(1).truncationMode(.middle)
                .help(text)
                .font(.system(size: Theme.fontSize.tab))
                .padding(.horizontal, Theme.settingsPagePadding)
                .padding(.vertical, Theme.sheetFooterPaddingV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1) }
        }
    }

    // MARK: Pages

    private var general: some View {
        SettingsSection {
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
            row(L10n.externalEditor) {
                TextField("", text: $model.externalEditor,
                          prompt: Text(L10n.externalEditorPlaceholder).foregroundStyle(Theme.ui.text3))
                    .modifier(CardField(mono: true))
                    .focused($editingExternal)
                    .onSubmit { model.commitExternalEditor() }
                    .onChange(of: editingExternal) { _, focused in if !focused { model.commitExternalEditor() } }
            }
        }
    }

    // Themes (themes-v1.html): three preview tiles; the terminal background follows the theme or Ghostty.
    private var appearance: some View {
        VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
            SettingsSection(title: L10n.themeTitle, card: false) {
                HStack(spacing: Theme.themeTileGap) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        ThemeTile(theme: theme, selected: Theme.current == theme) { save { try app.setTheme(theme) } }
                    }
                }
            }
            SettingsSection {
                row(L10n.terminalBackground, first: true) {
                    Segment(selection: app.config.terminalBackground,
                            options: [(.hangar, L10n.backgroundAsTheme), (.ghostty, L10n.backgroundGhostty)]) { bg in
                        save { try app.setTerminalBackground(bg) }
                    }
                }
            }
        }
    }

    // Settings → Editor (#84): the syntax palette, rainbow indents, TODO pills.
    private var editor: some View {
        SettingsSection {
            row(L10n.editorPaletteTitle, first: true) {
                Segment(selection: app.config.editorPalette, options: [(.darkPlus, "VS Code Dark+"), (.hangar, "Hangar")]) { p in
                    save { try app.setEditorAppearance("editor_palette", p.rawValue) { $0.editorPalette = p } }
                }
            }
            row(L10n.editorRainbowTitle) {
                SettingsSwitch(on: app.config.editorRainbowIndent) { on in
                    save { try app.setEditorAppearance("editor_rainbow_indent", flag: on) { $0.editorRainbowIndent = on } }
                }
            }
            row(L10n.editorTodoTitle) {
                SettingsSwitch(on: app.config.editorTodoHighlight) { on in
                    save { try app.setEditorAppearance("editor_todo_highlight", flag: on) { $0.editorTodoHighlight = on } }
                }
            }
        }
    }

    private var notifications: some View {
        SettingsSection {
            row(L10n.notificationsTitle, first: true) {
                SettingsSwitch(on: app.config.notifications) { on in
                    save { try app.setConfig("notifications", flag: on) { $0.notifications = on } }
                }
            }
            row(L10n.limitNotificationsTitle) {
                SettingsSwitch(on: app.config.limitNotifications) { on in
                    save { try app.setConfig("limit_notifications", flag: on) { $0.limitNotifications = on } }
                }
            }
            row(L10n.dockBadgeTitle) {
                SettingsSwitch(on: app.config.dockBadge) { on in
                    save { try app.setConfig("dock_badge", flag: on) { $0.dockBadge = on } }
                }
            }
            .help(L10n.dockBadgeHelp)
            row(L10n.keepAwakeShort) {
                SettingsSwitch(on: app.config.keepAwake) { on in
                    save { try app.setConfig("keep_awake", flag: on) { $0.keepAwake = on } }
                }
            }
            .help(L10n.keepAwakeTitle)
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
            SettingsSection {
                row(L10n.integrationClaude, first: true) { integrationValue(.claude) }
                row(L10n.integrationCodex) { integrationValue(.codex) }
                if model.integration.cli == nil { mcpValue }
            }
            // The commands to add Hangar's MCP server, one row per agent.
            if model.integration.cli != nil { SettingsSection(title: L10n.integrationMCP) { mcpValue } }
        }
    }

    private var advanced: some View {
        SettingsSection {
            row(L10n.configFile, first: true) {
                let path = tildePath(app.configURL.path)
                Text(verbatim: path)
                    .font(.system(size: Theme.fontSize.tab, design: .monospaced))
                    .foregroundStyle(Theme.ui.text2)
                    .lineLimit(1).truncationMode(.middle)
                    .help(path)
                Spacer(minLength: Theme.cardRowGap)
                Button(L10n.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([app.configURL]) }
                    .buttonStyle(SheetButton(primary: false))
                    .fixedSize()
            }
        }
    }

    // MARK: Integrations

    /// Status pill (the whole sentence in its tooltip), the file it writes, and the action (only after the consent sheet).
    @ViewBuilder private func integrationValue(_ target: IntegrationTarget) -> some View {
        let status = integrationStatus(target)
        let integration = model.integration
        Pill(text: status.pill, color: status.color).help(status.text)
        if integration.pathsReady, integration.cli != nil, target == .claude || integration.codex != .notFound {
            let path = tildePath((target == .claude ? integration.claudeSettings : integration.codexConfig).path)
            Text(verbatim: path)
                .font(.system(size: Theme.fontSize.counter, design: .monospaced))
                .foregroundStyle(Theme.ui.text3)
                .lineLimit(1).truncationMode(.middle)
                .help(path)
        }
        Spacer(minLength: Theme.cardRowGap)
        if let action = status.action {
            Button(action.title) { model.review(target, install: action.install) }
                .buttonStyle(SheetButton(primary: false))
                .fixedSize()
        }
    }

    /// Commands for the user to run in a terminal: Hangar itself never touches the agents' MCP configs.
    @ViewBuilder private var mcpValue: some View {
        if let cli = model.integration.cli {
            let commands = mcpAddCommands(cli: cli)
            ForEach(Array([("claude", commands.claude), ("codex", commands.codex)].enumerated()), id: \.offset) { i, item in
                row(item.0, first: i == 0) {
                    Text(verbatim: item.1)
                        .font(.system(size: Theme.fontSize.counter, design: .monospaced))
                        .foregroundStyle(Theme.ui.text2)
                        .lineLimit(1).truncationMode(.middle)
                        .help(item.1)
                    Spacer(minLength: Theme.cardRowGap)
                    Button(L10n.copyCommand) { model.copy(item.1) }
                        .buttonStyle(SheetButton(primary: false))
                        .fixedSize()
                }
            }
        } else {
            row(L10n.integrationMCP) {
                Pill(text: L10n.pillUnavailable, color: Theme.ui.text3).help(L10n.integrationNeedsApp)
                Text(verbatim: L10n.integrationNeedsApp).foregroundStyle(Theme.ui.text3).lineLimit(1).truncationMode(.tail)
                    .help(L10n.integrationNeedsApp)
            }
        }
    }

    private func integrationStatus(_ target: IntegrationTarget)
        -> (pill: String, text: String, color: Color, action: (title: String, install: Bool)?) {
        let integration = model.integration
        if model.pendingPlan == nil, integration.errorTarget == target, let error = integration.error {
            return (L10n.pillError, error, Theme.ui.failed, nil)
        }
        guard integration.pathsReady else { return (L10n.pillChecking, L10n.integrationChecking, Theme.ui.text3, nil) }
        let state: IntegrationState
        switch target {
        case .claude: state = integration.claude
        case .codex:
            switch integration.codex {
            case nil: return (L10n.pillChecking, L10n.codexLookup, Theme.ui.text3, nil)
            case .notFound?: return (L10n.pillUnavailable, L10n.codexNotFound, Theme.ui.text3, nil)
            case .found(let s)?: state = s
            }
        }
        guard let cli = integration.cli else { return (L10n.pillUnavailable, L10n.integrationNeedsApp, Theme.ui.text3, nil) }
        let pill = integrationPill(state)
        if installBlocked(cli: cli), state == .notInstalled || state == .outdated {
            return (pill.text, L10n.moveToApplications, pill.color, nil)  // removal stays possible from the other states
        }
        return switch state {
        case .installed: (pill.text, L10n.integrationInstalled, pill.color, (L10n.removeIntegration, false))
        case .installedStatuslineByUser: (pill.text, L10n.integrationStatuslineByUser, pill.color, (L10n.removeIntegration, false))
        case .outdated: (pill.text, L10n.integrationOutdated, pill.color, (L10n.updateEllipsis, true))
        case .notInstalled: (pill.text, target == .claude ? L10n.hooksMissing : L10n.codexNotifyMissing, pill.color, (L10n.installEllipsis, true))
        }
    }

    private func save(_ change: () throws -> Void) { model.save(change) }

    private func row(_ label: String, first: Bool = false, @ViewBuilder value: () -> some View) -> some View {
        CardRow(label: label, labelWidth: settingsLabelWidth(L10n.resolve(L10n.language)), first: first, value: value)
    }
}

/// The category list: icon + title, `selection` fill on the chosen one, `sbHover` under the pointer.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory
    @State private var hovered: SettingsCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.settingsNavGap) {
            ForEach(SettingsCategory.allCases) { category in
                let on = category == selection
                Button { selection = category } label: {
                    HStack(spacing: Theme.iconGap) {
                        IconView(icon: category.icon, tint: on ? Theme.ui.textStrong : Theme.ui.text2)
                        Text(verbatim: category.title).lineLimit(1)
                            .foregroundStyle(on ? Theme.ui.textStrong : Theme.ui.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.settingsSidebarPadding)
                    .frame(height: Theme.settingsNavRowHeight)
                    .background(RoundedRectangle(cornerRadius: Theme.settingsNavRadius)
                        .fill(on ? Theme.ui.selection : hovered == category ? Theme.ui.sidebarHover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand(!on)
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hovered = h ? category : (hovered == category ? nil : hovered) } }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.settingsSidebarPadding)
        .frame(width: Theme.settingsSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.ui.sidebar)
    }
}

/// A section of a page: an optional header on the card's left edge, then its card of rows (full page width).
private struct SettingsSection<Content: View>: View {
    var title: String?
    var card = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.settingsHeaderGap) {
            if let title {
                Text(verbatim: title)
                    .font(.system(size: Theme.fontSize.tab, weight: .semibold))
                    .foregroundStyle(Theme.ui.text2)
            }
            if card {
                VStack(spacing: 0) { content }
                    .frame(maxWidth: .infinity)
                    .sheetCard()
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// On/off switch (themes-v1.html `.sw`): `primary` track when on, `control` when off; the whole switch is the button.
struct SettingsSwitch: View {
    let on: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        let knob = Theme.switchHeight - 2 * Theme.switchInset
        Button { toggle(!on) } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.ui.primary : Theme.ui.control)
                Circle().fill(on ? Theme.ui.primaryText : Theme.ui.text2)
                    .frame(width: knob, height: knob)
                    .padding(.horizontal, Theme.switchInset)
            }
            .frame(width: Theme.switchWidth, height: Theme.switchHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .animation(Motion.ease(Theme.selectionFade), value: on)
        .accessibilityValue(on ? L10n.toggleOn : L10n.toggleOff)
    }
}

/// A theme as a tile (themes-v1.html `.tcard`): a mini window in its own colours over its name; the chosen one is
/// outlined in the current `accent`.
private struct ThemeTile: View {
    let theme: AppTheme
    let selected: Bool
    let choose: () -> Void
    @State private var hover = false

    private var name: String {
        switch theme {
        case .darkPlus: "VS Code Dark+"
        case .graphite: L10n.themeGraphite
        case .navy: "Hangar Navy"
        }
    }

    var body: some View {
        let p = ThemePalette.of(theme)
        let shape = RoundedRectangle(cornerRadius: Theme.themeTileRadius)
        Button { if !selected { choose() } } label: {
            VStack(spacing: Theme.settingsHeaderGap) {
                HStack(spacing: 0) {
                    Theme.ui.of(p.sidebar).frame(width: Theme.themeTileStrip)
                    VStack(alignment: .leading, spacing: Theme.themeTileLineGap) {
                        line(p.accent, 0.7)
                        line(p.tx2, 0.5)
                        line(p.gitA, 0.8)
                        line(p.gitM, 0.35)
                    }
                    .padding(Theme.themeTilePadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: Theme.themeTileHeight)
                .background(Theme.ui.of(p.editorBg))
                .clipShape(shape)
                .overlay(shape.strokeBorder(selected ? Theme.ui.accent : hover ? Theme.ui.controlBorderStrong : Theme.ui.control,
                                            lineWidth: selected ? Theme.themeTileBorder : 1))
                Text(verbatim: name).lineLimit(1)
                    .foregroundStyle(selected ? Theme.ui.textStrong : Theme.ui.text2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand(!selected)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A line of «code»: a bar in one of the theme's colours, `fraction` of the editor's width.
    private func line(_ color: Hex, _ fraction: CGFloat) -> some View {
        GeometryReader { g in
            Capsule().fill(Theme.ui.of(color)).frame(width: g.size.width * fraction)
        }
        .frame(height: Theme.themeTileLine)
    }
}

/// Integration status: a word in its colour on that colour at 15 %.
private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: Theme.fontSize.tab))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Theme.pillPaddingH)
            .frame(height: Theme.pillHeight)
            .background(Capsule().fill(color.opacity(Theme.pillFillOpacity)))
            .fixedSize()
    }
}

/// Segmented control in the token colors (`field` track, `control` active segment): only for real choices.
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
