import AppKit
import Integration
import AgentStatus
import SwiftUI
import UserNotifications
import Workspace

/// A page of the settings window, in the order of its list.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, notifications, integrations, advanced

    var id: Self { self }

    var titleKey: L10n.Key {
        switch self {
        case .general: .settingsGeneral
        case .appearance: .appearance
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
        case .notifications: .bell
        case .integrations: .plug
        case .advanced: .more
        }
    }

    /// The row labels of the page: the label column is measured from them.
    var labelKeys: [L10n.Key] {
        switch self {
        case .general: [.languageTitle, .defaultAgent, .externalEditor, .checkUpdatesTitle, .versionTitle]
        case .appearance: [.edFont, .edSize, .edLineHeight, .edLigatures, .edTabSize, .edDetect, .edWrap, .edLineHighlight, .edCursor,
                           .edBlink, .edWhitespace, .edBracketColors, .edBracketGuides, .edIndentGuides, .editorRainbowTitle, .editorTodoTitle]
        case .notifications:
            [.notificationsTitle, .notifyPermissionTitle, .notifyQuestionTitle, .notifyFailedTitle, .limitNotificationsTitle, .notifyDoneTitle,
             .allowFromNotificationTitle, .notifyWhenActiveTitle, .dockBadgeTitle, .sshTerminalBellTitle, .keepAwakeShort, .notificationPermissionTitle]
        case .integrations: [.integrationClaude, .integrationCodex, .integrationMCP, .statuslineShow]
        case .advanced: [.configFile, .edFormatOnSave]
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

struct SettingsView: View {
    @Bindable var model: SettingsModel
    var app: AppState { model.app }
    @FocusState private var editingExternal: Bool
    @State private var authorization: UNAuthorizationStatus?

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
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    model.editorTheme.pageHeight = $0.height
                    model.editorTheme.pageWidth = $0.width - 2 * Theme.settingsPagePadding
                }
                footer
            }
        }
        // Width only: the window's minimum is a frame size (title bar included); a content minHeight of the same
        // value overflowed the window at its minimum and cut 14 pt off the page's top and bottom.
        .frame(minWidth: Theme.settingsMinSize.width)
        .font(.system(size: Theme.fontSize.sheetRow))
        .background(Theme.ui.sheet)
    }

    @ViewBuilder private var page: some View {
        switch model.category {
        case .general: general
        case .appearance: appearance
        case .notifications: notifications
        case .integrations: integrations
        case .advanced: advanced
        }
    }

    /// A write error or an integration message, under the page (nothing when all is well: no jump of the cards).
    @ViewBuilder private var footer: some View {
        if let text = model.error ?? (model.category == .appearance ? model.editorTheme.notice : nil) {
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
        CardSection {
            row(L10n.languageTitle, first: true) {
                Segmented(selection: app.language, options: [
                    (.system, L10n.languageSystem), (.ru, L10n.languageRu), (.en, L10n.languageEn),
                ]) { lang in save { try app.setLanguage(lang) } }
            }
            row(L10n.defaultAgent) {
                Segmented(selection: app.config.defaultAgent, options: [(.claude, "claude"), (.codex, "codex")]) { kind in
                    save { try app.setConfig("default_agent", kind.rawValue) { $0.defaultAgent = kind } }
                }
            }
            row(L10n.externalEditor) {
                TextField("", text: $model.externalEditor)
                    .focused($editingExternal)
                    .inputField(focused: editingExternal, mono: true,
                                placeholder: model.externalEditor.isEmpty ? L10n.externalEditorPlaceholder : nil)
                    .onSubmit { model.commitExternalEditor() }
                    .onChange(of: editingExternal) { _, focused in if !focused { model.commitExternalEditor() } }
            }
            row(L10n.checkUpdatesTitle) {
                CardSwitch(on: app.config.checkUpdates) { on in
                    save { try app.setConfig("check_updates", flag: on) { $0.checkUpdates = on } }
                    if on { app.updates.checkIfDue() }
                }
                .disabled(app.updates.feed == nil)
            }
            row(L10n.versionTitle) { versionValue }
        }
    }

    /// The running version, the last check's outcome, «Проверить сейчас» (#86).
    @ViewBuilder private var versionValue: some View {
        let updates = app.updates
        let status = updateStatus(updates)
        Text(verbatim: updates.current ?? "dev")
            .font(.system(size: Theme.fontSize.tab, design: .monospaced))
            .foregroundStyle(Theme.ui.text2)
            .fixedSize()
        if let status {
            Text(verbatim: status.text).foregroundStyle(status.color)
                .lineLimit(1).truncationMode(.middle)
                .help(status.text)
                .layoutPriority(1)  // the download progress stays readable next to the buttons
        }
        Spacer(minLength: Theme.cardRowGap)
        // An update found: «Обновить до X» (the sheet's flow: download, check, the usual quit with its confirmation,
        // relaunch) takes the place of «Проверить сейчас» — both don't fit the row. While it downloads, only the progress.
        switch updates.settingsButton {
        case .install(let version): installButton(L10n.updateTo(version), updates)
        case .restart: installButton(L10n.updateRestart, updates)
        case .busy: EmptyView()
        case nil:
            Button(L10n.checkNow) { updates.checkNow() }
                .buttonStyle(.hangar(.secondary))
                .fixedSize()
                .disabled(updates.feed == nil || updates.phase == .checking)
        }
    }

    private func installButton(_ title: String, _ updates: UpdateModel) -> some View {
        Button(title) { updates.install() }
            .buttonStyle(.hangar(.primary))
            .fixedSize()
    }

    private func updateStatus(_ updates: UpdateModel) -> (text: String, color: Color)? {
        guard updates.feed != nil else { return (L10n.updateDevBuild, Theme.ui.text3) }
        switch updates.phase {
        case .checking: return (L10n.updateChecking, Theme.ui.text3)
        case .checkFailed(let why): return (L10n.updateCheckFailed(why), Theme.ui.failedText)
        case .downloading(let p): return (p.map { L10n.updateDownloading(Int($0 * 100)) } ?? L10n.updateDownloadingPlain, Theme.ui.text2)
        case .preparing: return (L10n.updatePreparing, Theme.ui.text2)
        case .ready: return (L10n.updateReady, Theme.ui.done)
        case .otherInstance: return (L10n.updateOtherInstance, Theme.ui.waiting)
        case .manual: return (L10n.updateManual(tildePath(updates.bundle.deletingLastPathComponent().path)), Theme.ui.waiting)
        case .failed(let why): return (L10n.updateFailed(why), Theme.ui.failedText)
        default:
            if updates.offer != nil { return nil }  // «Обновить до X» says it
            return updates.record.lastCheck != nil ? (L10n.updateUpToDate, Theme.ui.text3) : nil
        }
    }

    // Settings → Advanced → language servers (#102, #109): status per language, download / remove Hangar's own copies.
    var languageServers: some View {
        CardSection(title: L10n.lspSection) {
            ForEach(Array(LspServersModel.rows.enumerated()), id: \.element.id) { i, r in
                row(r.name, first: i == 0) { lspValue(r) }
            }
        }
        .task { await model.lsp.refresh() }
    }

    @ViewBuilder private func lspValue(_ row: LspServersModel.Row) -> some View {
        let lsp = model.lsp
        let package: LspPackage? = if case .package(let p) = row.kind { p } else { nil }
        let job = package.flatMap { lsp.jobs[$0] }
        switch (row.kind, lsp.status(row)) {
        case (.project, _):
            Pill(text: L10n.lspFromProject, color: Theme.ui.text2)
            lspDetail(L10n.lspTsDetail, mono: false)
            Spacer(minLength: Theme.cardRowGap)
        case (_, .checking):
            Pill(text: L10n.pillChecking, color: Theme.ui.text3)
            Spacer(minLength: Theme.cardRowGap)
        case (_, .installed(let source, let executable)):
            Pill(text: L10n.lspInstalledFrom(lspSource(source)), color: Theme.ui.done).help(executable)
            lspDetail(tildePath(executable))
            Spacer(minLength: Theme.cardRowGap)
            if let package, lsp.owned.contains(package), job == nil {
                Button(L10n.lspRemove) { lsp.remove(package) }
                    .buttonStyle(.hangar(.secondary))
                    .fixedSize()
            }
        case (_, .missing):
            if let package {
                lspMissing(package, job)
            } else {
                Pill(text: L10n.lspNeedsXcode, color: Theme.ui.waiting)
                lspDetail(L10n.lspXcodeTip, mono: false)
                Spacer(minLength: Theme.cardRowGap)
            }
        }
    }

    /// A missing downloadable server: its download's progress or error (in place of the pill, so it has room), else
    /// «Не установлен» and «Скачать» (or what it needs first).
    @ViewBuilder private func lspMissing(_ package: LspPackage, _ job: LspServersModel.Job?) -> some View {
        let lsp = model.lsp
        switch job {
        case .running(let fraction)?:
            lspDetail(fraction.map { L10n.lspDownloading(Int($0 * 100)) } ?? L10n.lspInstalling, color: Theme.ui.text2, mono: false)
            Spacer(minLength: Theme.cardRowGap)
            Button(L10n.cancel) { lsp.cancel(package) }
                .buttonStyle(.hangar(.secondary))
                .fixedSize()
        case .failed(let why)?:
            lspDetail(why, color: Theme.ui.failedText, mono: false)
            Spacer(minLength: Theme.cardRowGap)
            Button(L10n.lspRetry) { lsp.install(package) }
                .buttonStyle(.hangar(.secondary))
                .fixedSize()
        case nil:
            Pill(text: L10n.lspNotInstalled, color: Theme.ui.waiting)
            Spacer(minLength: Theme.cardRowGap)
            if package.tool != nil, lsp.tools[package] == nil {
                Text(verbatim: package == .pyright ? L10n.lspNeedsNode : L10n.lspNeedsGo)
                    .foregroundStyle(Theme.ui.text3)
            } else {
                Button(L10n.lspDownload) { lsp.install(package) }
                    .buttonStyle(.hangar(.secondary))
                    .fixedSize()
                    .help(L10n.lspDownloadTip(package.rawValue, tildePath(lsp.env.dir)))
            }
        }
    }

    private func lspSource(_ source: LspServersModel.Source) -> String {
        switch source {
        case .project: L10n.lspSourceProject
        case .path: "PATH"
        case .hangar(let version): version.isEmpty ? "Hangar" : "Hangar " + version
        case .toolchain: "Xcode"
        }
    }

    private func lspDetail(_ text: String, color: Color = Theme.ui.text3, mono: Bool = true) -> some View {
        Text(verbatim: text)
            .font(.system(size: mono ? Theme.fontSize.counter : Theme.fontSize.tab, design: mono ? .monospaced : .default))
            .foregroundStyle(color)
            .lineLimit(1).truncationMode(mono ? .middle : .tail)
            .help(text)
    }

    /// Three sections (DESIGN «секции через 20»): the master switch and macOS's permission; the events, dimmed while the
    /// master is off (they only shape the banners); the Dock badge, SSH bell and sleep, which work without banners.
    private var notifications: some View {
        let on = app.config.notifications
        return VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
            CardSection {
                row(L10n.notificationsTitle, first: true) {
                    CardSwitch(on: on) { on in
                        save { try app.setConfig("notifications", flag: on) { $0.notifications = on } }
                    }
                }
                if app.notificationAuthorization != nil { permissionRow }
            }
            CardSection(title: L10n.notifySectionEvents) {
                ForEach(Array(notificationReasons.enumerated()), id: \.element) { i, reason in
                    row(reasonTitle(reason), first: i == 0) {
                        CardSwitch(on: app.notifyEnabled(reason)) { on in save { try app.setNotify(reason, on) } }
                        Spacer(minLength: Theme.cardRowGap)
                        soundMenu(reason)
                    }
                }
                // S1 = A: the Allow button exists; off by default, with its risk in the tooltip.
                row(L10n.allowFromNotificationTitle) {
                    CardSwitch(on: app.config.allowFromNotification) { on in
                        save { try app.setConfig("allow_from_notification", flag: on) { $0.allowFromNotification = on } }
                    }
                }
                .help(L10n.allowFromNotificationHelp)
                row(L10n.notifyWhenActiveTitle) {
                    CardSwitch(on: app.config.notifyWhenActive) { on in
                        save { try app.setConfig("notify_when_active", flag: on) { $0.notifyWhenActive = on } }
                    }
                }
                .help(L10n.notifyWhenActiveHelp)
            }
            .opacity(on ? 1 : Theme.inactiveOpacity)
            .disabled(!on)
            CardSection(title: L10n.notifySectionSystem) {
                row(L10n.dockBadgeTitle, first: true) {
                    CardSwitch(on: app.config.dockBadge) { on in
                        save { try app.setConfig("dock_badge", flag: on) { $0.dockBadge = on } }
                    }
                }
                .help(L10n.dockBadgeHelp)
                row(L10n.sshTerminalBellTitle) {
                    CardSwitch(on: app.config.sshTerminalBell) { on in
                        save { try app.setConfig("ssh_terminal_bell", flag: on) { $0.sshTerminalBell = on } }
                    }
                }
                .help(L10n.sshTerminalBellHelp)
                row(L10n.keepAwakeShort) {
                    CardSwitch(on: app.config.keepAwake) { on in
                        save { try app.setConfig("keep_awake", flag: on) { $0.keepAwake = on } }
                    }
                }
                .help(L10n.keepAwakeTitle)
            }
        }
        .task { authorization = await app.notificationAuthorization?() }
        // The switch is flipped in System Settings: re-read it when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { authorization = await app.notificationAuthorization?() }
        }
    }

    private var notificationReasons: [AttentionReason] { [.permission, .question, .failed, .limit, .done] }

    private func reasonTitle(_ reason: AttentionReason) -> String {
        switch reason {
        case .permission: L10n.notifyPermissionTitle
        case .question: L10n.notifyQuestionTitle
        case .failed: L10n.notifyFailedTitle
        case .limit: L10n.limitNotificationsTitle
        case .done: L10n.notifyDoneTitle
        }
    }

    /// S4 = no named system sounds: «Без звука» and «Стандартный» only.
    private func soundMenu(_ reason: AttentionReason) -> some View {
        let current = app.config.sounds[reason.rawValue] ?? "default"
        return HStack(spacing: Theme.pickGap) {
            Text(verbatim: current.isEmpty ? L10n.soundNone : L10n.soundDefault)
                .foregroundStyle(Theme.ui.text3)
            PopoverMenuButton(icon: .chevronDown, help: L10n.soundTitle) {
                [("", L10n.soundNone), ("default", L10n.soundDefault)].map { value, title in
                    .item(PopoverMenuItem(title: title, icon: (current.isEmpty ? "" : "default") == value ? .check : nil) {
                        save { try app.setSound(reason, value) }
                    })
                }
            }
        }
    }

    /// macOS's own switch for Hangar's banners; «Открыть системные настройки» when it is off. The urgent-level note (S3 = T-no) sits here.
    private var permissionRow: some View {
        let state = notificationPermission(authorization)
        return row(L10n.notificationPermissionTitle) {
            VStack(alignment: .leading, spacing: Theme.pickGap) {
                HStack(spacing: Theme.cardRowGap) {
                    Text(verbatim: state.text).foregroundStyle(state.denied ? Theme.ui.failedText : Theme.ui.text2)
                    if state.denied, let url = notificationSettingsURL(bundleId: Bundle.main.bundleIdentifier ?? "") {
                        Button(L10n.openSystemSettings) { NSWorkspace.shared.open(url) }
                            .buttonStyle(.hangar(.secondary))
                            .fixedSize()
                    }
                }
                Text(verbatim: L10n.urgentNotice)
                    .font(.system(size: Theme.fontSize.tab))
                    .foregroundStyle(Theme.ui.text3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The config file; then what the editor does through tsserver / language servers (#109: not the look, so not in
    /// «Оформление»): format on save and the servers themselves.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
            CardSection {
                configFileRow
            }
            CardSection(title: L10n.editor) {
                row(L10n.s(.edFormatOnSave), first: true) {
                    CardSwitch(on: app.config.editorOptions.formatOnSave) { on in
                        save { try app.setEditorAppearance("editor_format_on_save", flag: on) { $0.editorOptions.formatOnSave = on } }
                    }
                    .help(L10n.s(.edFormatTip))
                }
            }
            languageServers
        }
    }

    private var configFileRow: some View {
        row(L10n.configFile, first: true) {
            let path = tildePath(app.configURL.path)
            Text(verbatim: path)
                .font(.system(size: Theme.fontSize.tab, design: .monospaced))
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1).truncationMode(.middle)
                .help(path)
            Spacer(minLength: Theme.cardRowGap)
            Button(L10n.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([app.configURL]) }
                .buttonStyle(.hangar(.secondary))
                .fixedSize()
        }
    }

    func save(_ change: () throws -> Void) { model.save(change) }

    func row(_ label: String, first: Bool = false, @ViewBuilder value: () -> some View) -> some View {
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
                .onHover { h in hovered = h ? category : (hovered == category ? nil : hovered) }
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

/// The macOS permission line: the words, and whether it is off (then the button to System Settings shows).
@MainActor func notificationPermission(_ status: UNAuthorizationStatus?) -> (text: String, denied: Bool) {
    switch status {
    case .denied: (L10n.notificationsDeniedInSystem, true)
    case .notDetermined, nil: (L10n.notificationsNotAsked, false)
    default: (L10n.notificationsAllowedInSystem, false)
    }
}

func notificationSettingsURL(bundleId: String) -> URL? {
    URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)")
}
