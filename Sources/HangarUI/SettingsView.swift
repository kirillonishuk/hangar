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
                // The 52 header shares its bar with the traffic lights (a unified toolbar of no items).
                Text(verbatim: model.category.title)
                    .font(Theme.Typography.title.font(.semibold))
                    .foregroundStyle(Theme.ui.text0)
                    .padding(.horizontal, Theme.settingsPagePaddingH)
                    .frame(maxWidth: .infinity, minHeight: Theme.settingsHeaderHeight, maxHeight: Theme.settingsHeaderHeight, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
                    // Over the page: a scrolled page draws past its clip view (AppKit doesn't clip it) under the header.
                    .background(Theme.ui.bg0)
                    .zIndex(1)
                ScrollView {
                    page
                        .padding(.vertical, Theme.settingsPagePaddingV)
                        .padding(.horizontal, Theme.settingsPagePaddingH)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.settingsCards, true)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    model.editorTheme.pageHeight = $0.height
                    model.editorTheme.pageWidth = $0.width - 2 * Theme.settingsPagePaddingH
                }
                footer
            }
        }
        // Width only: the window's minimum is a frame size (title bar included); a content minHeight of the same
        // value overflowed the window at its minimum and cut 14 pt off the page's top and bottom.
        .frame(minWidth: Theme.settingsMinSize.width)
        .font(Theme.Typography.body.font())
        .background(Theme.ui.bg0)
        .ignoresSafeArea(.container, edges: .top)
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
                .font(Theme.Typography.secondary.font())
                .padding(.horizontal, Theme.settingsPagePaddingH)
                .padding(.vertical, Theme.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        }
    }

    // MARK: Pages

    private var general: some View {
        VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
            CardSection {
                row(L10n.languageTitle, first: true) {
                    Segmented(selection: app.language, options: [
                        (.system, L10n.languageSystem), (.ru, L10n.languageRu), (.en, L10n.languageEn),
                    ]) { lang in save { try app.setLanguage(lang) } }
                }
                row(L10n.defaultAgent, hint: L10n.s(.defaultAgentHint)) {
                    Segmented(selection: app.config.defaultAgent, options: [(.claude, "claude"), (.codex, "codex")]) { kind in
                        save { try app.setConfig("default_agent", kind.rawValue) { $0.defaultAgent = kind } }
                    }
                }
                row(L10n.externalEditor, hint: L10n.s(.externalEditorHint)) {
                    TextField("", text: $model.externalEditor)
                        .focused($editingExternal)
                        .inputField(focused: editingExternal, mono: true,
                                    placeholder: model.externalEditor.isEmpty ? L10n.externalEditorPlaceholder : nil)
                        .onSubmit { model.commitExternalEditor() }
                        .onChange(of: editingExternal) { _, focused in if !focused { model.commitExternalEditor() } }
                        .frame(minWidth: Theme.settingsFieldWidth / 2, maxWidth: Theme.settingsFieldWidth)
                }
            }
            CardSection(title: L10n.s(.updatesSection)) {
                row(L10n.checkUpdatesTitle, first: true) {
                    CardSwitch(on: app.config.checkUpdates) { on in
                        save { try app.setConfig("check_updates", flag: on) { $0.checkUpdates = on } }
                        if on { app.updates.checkIfDue() }
                    }
                    .disabled(app.updates.feed == nil)
                }
                versionRow
            }
        }
    }

    /// «Версия 0.8.0», the last check's outcome under it, «Проверить сейчас» on the right (#86).
    private var versionRow: some View {
        let updates = app.updates
        let status = updateStatus(updates)
        return SettingsRow(label: L10n.versionTitle) {
            // One text, so the outcome wraps under the version instead of being cut.
            (Text(verbatim: updates.current ?? "dev").font(Theme.Typography.monoSmall.font()).foregroundColor(Theme.ui.text2)
                + Text(verbatim: status.map { "  " + $0.text } ?? "").foregroundColor(status?.color ?? Theme.ui.text3))
                .help(status?.text ?? "")
        } value: {
            // An update found: «Обновить до X» (the sheet's flow: download, check, the usual quit with its confirmation,
            // relaunch) takes the place of «Проверить сейчас». While it downloads, only the progress.
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
    // The row: the language, where the server is (or what it needs) under it; the status and the action on the right.
    var languageServers: some View {
        CardSection(title: L10n.lspSection) {
            ForEach(Array(LspServersModel.rows.enumerated()), id: \.element.id) { i, r in
                SettingsRow(label: r.name, first: i == 0) { lspDetail(r) } value: { lspValue(r) }
            }
        }
        .task { await model.lsp.refresh() }
    }

    private func lspPackage(_ row: LspServersModel.Row) -> LspPackage? {
        if case .package(let p) = row.kind { p } else { nil }
    }

    @ViewBuilder private func lspDetail(_ row: LspServersModel.Row) -> some View {
        let lsp = model.lsp
        let package = lspPackage(row)
        switch (row.kind, lsp.status(row), package.flatMap { lsp.jobs[$0] }) {
        case (.project, _, _): lspLine(L10n.lspTsDetail, mono: false)
        case (_, .installed(_, let executable), _): lspLine(tildePath(executable))
        case (_, .missing, .running(let fraction)?):
            lspLine(fraction.map { L10n.lspDownloading(Int($0 * 100)) } ?? L10n.lspInstalling, color: Theme.ui.text2, mono: false)
        case (_, .missing, .failed(let why)?): lspLine(why, color: Theme.ui.failedText, mono: false)
        case (_, .missing, nil):
            if package == nil { lspLine(L10n.lspXcodeTip, mono: false) }
            else if let package, package.tool != nil, lsp.tools[package] == nil {
                lspLine(package == .pyright ? L10n.lspNeedsNode : L10n.lspNeedsGo, mono: false)
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func lspValue(_ row: LspServersModel.Row) -> some View {
        let lsp = model.lsp
        let package = lspPackage(row)
        let job = package.flatMap { lsp.jobs[$0] }
        switch (row.kind, lsp.status(row)) {
        case (.project, _): Pill(text: L10n.lspFromProject, color: Theme.ui.text2)
        case (_, .checking): Pill(text: L10n.pillChecking, color: Theme.ui.text3)
        case (_, .installed(let source, let executable)):
            Pill(text: L10n.lspInstalledFrom(lspSource(source)), color: Theme.ui.done).help(executable)
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
            }
        }
    }

    /// A missing downloadable server: «Отмена» while it downloads, «Повторить» after an error (the progress or the
    /// error is the row's line), else «Не установлен» and «Скачать» (unless it needs a tool first).
    @ViewBuilder private func lspMissing(_ package: LspPackage, _ job: LspServersModel.Job?) -> some View {
        let lsp = model.lsp
        switch job {
        case .running?:
            Button(L10n.cancel) { lsp.cancel(package) }
                .buttonStyle(.hangar(.secondary))
                .fixedSize()
        case .failed?:
            Button(L10n.lspRetry) { lsp.install(package) }
                .buttonStyle(.hangar(.secondary))
                .fixedSize()
        case nil:
            Pill(text: L10n.lspNotInstalled, color: Theme.ui.waiting)
            if package.tool == nil || lsp.tools[package] != nil {
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

    private func lspLine(_ text: String, color: Color = Theme.ui.text3, mono: Bool = true) -> some View {
        Text(verbatim: text)
            .font((mono ? Theme.Typography.monoSmall : Theme.Typography.secondary).font())
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
                        soundMenu(reason)
                        CardSwitch(on: app.notifyEnabled(reason)) { on in save { try app.setNotify(reason, on) } }
                    }
                }
                // S1 = A: the Allow button exists; off by default, with its risk in the tooltip.
                row(L10n.allowFromNotificationTitle, hint: L10n.allowFromNotificationHelp) {
                    CardSwitch(on: app.config.allowFromNotification) { on in
                        save { try app.setConfig("allow_from_notification", flag: on) { $0.allowFromNotification = on } }
                    }
                }
                row(L10n.notifyWhenActiveTitle, hint: L10n.notifyWhenActiveHelp) {
                    CardSwitch(on: app.config.notifyWhenActive) { on in
                        save { try app.setConfig("notify_when_active", flag: on) { $0.notifyWhenActive = on } }
                    }
                }
            }
            .opacity(on ? 1 : Theme.Opacity.inactive)
            .disabled(!on)
            CardSection(title: L10n.notifySectionSystem) {
                row(L10n.dockBadgeTitle, hint: L10n.dockBadgeHelp, first: true) {
                    CardSwitch(on: app.config.dockBadge) { on in
                        save { try app.setConfig("dock_badge", flag: on) { $0.dockBadge = on } }
                    }
                }
                row(L10n.sshTerminalBellTitle, hint: L10n.sshTerminalBellHelp) {
                    CardSwitch(on: app.config.sshTerminalBell) { on in
                        save { try app.setConfig("ssh_terminal_bell", flag: on) { $0.sshTerminalBell = on } }
                    }
                }
                row(L10n.keepAwakeShort, hint: L10n.keepAwakeTitle) {
                    CardSwitch(on: app.config.keepAwake) { on in
                        save { try app.setConfig("keep_awake", flag: on) { $0.keepAwake = on } }
                    }
                }
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
        return HStack(spacing: Theme.Space.s1) {
            Text(verbatim: current.isEmpty ? L10n.soundNone : L10n.soundDefault)
                .foregroundStyle(Theme.ui.text3)
                .fixedSize()
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
        return SettingsRow(label: L10n.notificationPermissionTitle) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: state.text).foregroundStyle(state.denied ? Theme.ui.failedText : Theme.ui.text2)
                Text(verbatim: L10n.urgentNotice)
            }
        } value: {
            if state.denied, let url = notificationSettingsURL(bundleId: Bundle.main.bundleIdentifier ?? "") {
                Button(L10n.openSystemSettings) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.hangar(.secondary))
                    .fixedSize()
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
                row(L10n.s(.edFormatOnSave), hint: L10n.s(.edFormatTip), first: true) {
                    CardSwitch(on: app.config.editorOptions.formatOnSave) { on in
                        save { try app.setEditorAppearance("editor_format_on_save", flag: on) { $0.editorOptions.formatOnSave = on } }
                    }
                }
            }
            languageServers
        }
    }

    private var configFileRow: some View {
        let path = tildePath(app.configURL.path)
        return SettingsRow(label: L10n.configFile, first: true) {
            Text(verbatim: path)
                .font(Theme.Typography.monoSmall.font())
                .lineLimit(1).truncationMode(.middle)
                .help(path)
        } value: {
            Button(L10n.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([app.configURL]) }
                .buttonStyle(.hangar(.secondary))
                .fixedSize()
        }
    }

    func save(_ change: () throws -> Void) { model.save(change) }

    func row<V: View>(_ label: String, hint: String? = nil, first: Bool = false, @ViewBuilder value: () -> V) -> some View {
        SettingsRow(label, hint: hint, first: first, value: value)
    }
}

/// The category list (216, `bg1`, rows 28 with a 16 icon): icon + title, `selectedFocus` fill and `onAccent` on the chosen one, `hover` under the pointer.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory
    @State private var hovered: SettingsCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsCategory.allCases) { category in
                let on = category == selection
                Button { selection = category } label: {
                    HStack(spacing: Theme.Space.iconGap) {
                        IconView(icon: category.icon, size: Theme.Icon.toolbar, tint: on ? Theme.ui.onAccent : Theme.ui.text2)
                        Text(verbatim: category.title).lineLimit(1)
                            .foregroundStyle(on ? Theme.ui.onAccent : Theme.ui.text1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Space.s2)
                    .frame(height: Theme.Height.rowSidebar)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(on ? Theme.ui.selectedFocus : hovered == category ? Theme.ui.hover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand(!on)
                .onHover { h in hovered = h ? category : (hovered == category ? nil : hovered) }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s2)
        .padding(.bottom, Theme.Space.s2)
        .padding(.top, Theme.settingsHeaderHeight)  // under the traffic lights
        .frame(width: Theme.settingsSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.ui.bg1)
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
