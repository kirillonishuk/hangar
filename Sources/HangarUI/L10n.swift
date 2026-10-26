import AgentStatus
import Foundation
import GhosttyBridge
import Observation
import Workspace

/// Every UI string (decision #38): `Resources/<lang>.lproj/Localizable.strings`, keys = `Key` cases.
/// Reading a string inside a SwiftUI body observes `language`, so switching it redraws the UI live.
@MainActor public enum L10n {
    /// Observable holder of the chosen language (a static stored property can't be observed).
    @Observable final class Selection {
        var language: Language = .system
    }
    static let selection = Selection()

    /// The setting (`system` / `ru` / `en`); set from config at launch and from Settings.
    public static var language: Language {
        get { selection.language }
        set { selection.language = newValue }
    }

    /// `system` → ru if the first preferred language is Russian, else en.
    nonisolated static func resolve(_ language: Language, preferred: [String] = Locale.preferredLanguages) -> Language {
        guard language == .system else { return language }
        return preferred.first.map { Locale(identifier: $0).language.languageCode?.identifier == "ru" } == true ? .ru : .en
    }

    /// SwiftPM's generated `Bundle.module` fatalErrors when the bundle is missing, so it is never used: look in
    /// Contents/Resources (bundle.sh), next to the executable (`swift run`), and in DEBUG next to the test
    /// bundle in .build. Nothing found → strings fall back to their key names instead of crashing.
    nonisolated static let resources: Bundle? = {
        var dirs = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        #if DEBUG
        dirs.append(Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent())
        #endif
        return findResources(in: dirs)
    }()
    private final class BundleMarker {}

    nonisolated static func findResources(in dirs: [URL?]) -> Bundle? {
        for case let dir? in dirs {
            if let bundle = Bundle(url: dir.appendingPathComponent("Hangar_HangarUI.bundle")) { return bundle }
        }
        return nil
    }

    nonisolated private static func lproj(_ lang: Language, in resources: Bundle?) -> Bundle? {
        resources?.url(forResource: lang.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:))
    }

    nonisolated private static let lprojBundles: [Language: Bundle] = {
        var out: [Language: Bundle] = [:]
        for lang in [Language.ru, .en] { out[lang] = lproj(lang, in: resources) }
        return out
    }()

    /// Raw table of one language (tests check that ru and en have exactly the `Key` set).
    nonisolated static func table(_ lang: Language) -> [String: String]? {
        guard let url = lprojBundles[lang]?.url(forResource: "Localizable", withExtension: "strings") else { return nil }
        return NSDictionary(contentsOf: url) as? [String: String]
    }

    /// `key` in `lang` from `resources`; the key name when the bundle or the key is missing.
    nonisolated static func lookup(_ key: Key, _ lang: Language, in resources: Bundle?) -> String {
        let bundle = resources === Self.resources ? lprojBundles[lang] : lproj(lang, in: resources)
        return bundle?.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil) ?? key.rawValue
    }

    static func s(_ key: Key) -> String { lookup(key, resolve(language), in: resources) }

    private static func f(_ key: Key, _ args: CVarArg...) -> String {
        String(format: s(key), locale: Locale(identifier: resolve(language).rawValue), arguments: args)
    }

    nonisolated enum Key: String, CaseIterable, Sendable {
        case sectionPinned, sectionProjects, sectionArchived, sectionSSHHosts, newTask, newTaskHelp
        case newTaskIn, addProject, addProjectEllipsis, restore, rename
        case pin, unpin, archive, folderMissing
        case statusWorking, statusWaiting, statusDone, statusFailed, statusIdle, statusLimit, limitUntil, rowWithStatus
        case folderMissingPath, more, settings, settingsHelp, settingsEllipsis
        case collapseSidebarHelp, expandSidebarHelp, inspectorHelp, diffUnavailable, newTabHelp, closeTabHelp, allTabsHelp
        case taskNamePlaceholder, firstMessagePlaceholder, escCancel, cancel, create, configNotApplied
        case usingDefaults, launchFailed, terminalCreateFailed, exited, exitedWithCode, relaunchHint, hostNotConnected, hostOffline, remoteNoGit, sessionDetached
        case emptyNoTask, emptyNoTabs, ghosttyFailed, retry, quit, menuHide
        case menuQuit, menuEdit, undo, redo, cut, copy
        case paste, selectAll, languageTitle, languageSystem, languageRu, languageEn
        case defaultAgent, editor, externalEditor, externalEditorPlaceholder, terminalBackground, backgroundTheme
        case afterRestart, saveFailed
        case notificationsTitle, limitNotificationsTitle, toggleOn, toggleOff, agentWaiting, agentDone
        case revealInFinder, copyPath, portCopy, openIn, openFailed, deletePermanently, deleteTaskConfirm, deleteTaskInfo, delete
        case copyLink, attentionOnly, nobodyWaiting
        case alsoDeleteWorktree, worktreeDirty, worktreeDirtyInfo, worktreeIgnored, worktreeIgnoredInfo, deleteAnyway, worktreeRemoveFailed, branchKept
        case projectSettingsEllipsis, projectSettings, removeFromHangar, removeProjectConfirm, removeProjectInfo, remove, splitRight, splitDown
        case drawerTitle, drawerToggle, drawerHelp
        case closeTab, projectName, projectPath, chooseEllipsis, defaultBranch, worktreeFolder, creatingWorktreeWait, worktreeRootInsideProject, pathMustBeAbsolute, branchAuto, save
        case ok, exitStatus, stateCorrupt, stateUnreadable
        case clipboardRead, clipboardPasteUnsafe, allow
        case branchRequired, branchInvalid, branchExists, fetchFailed, createWithoutFetch, fetchCancelled, noCommits
        case worktreeLabel, worktreeOnHint, worktreeOffHint, fromBranch, newBranch, fromName, currentBranch, refreshHelp
        case searchBranches, branchesRemote, branchesLocal, branchDefault, branchTask
        case updatedAgo, justNow, minutesAgo, hoursAgo, daysAgo
        case agentsWorking, agentsWorkingInfo
        case keepAwakeTitle
        case keepAwakeOffHelp, keepAwakeIdleHelp, keepAwakeActiveHelp, keepAwakeGraceHelp
        case limitSession, limitWeekAll, limitWeek, limitWeekModel, resetIn, durationMin, durationHourMin, durationDayHour
        case limitAlmost, limitReached, limitBadgeAlmost, limitBadgeFull, limitsShortcutHint, refresh, limitsHelp
        case integrationClaude, integrationCodex, integrationInstalled, integrationStatuslineByUser, integrationOutdated
        case hooksMissing, codexNotifyMissing, installEllipsis, updateEllipsis, removeIntegration, codexNotFound, codexLookup
        case integrationNeedsApp, settingsInvalidJSON, settingsUnsupported, fileChanged, codexConfigUnsupported, integrationWriteFailed
        case integrationConfirmTitle, backupWillBeCreated, backupCreated, linesUnchanged, apply, moveToApplications, integrationChecking
        case integrationMCP, copyCommand, commandCopied, mcpHint, dockBadgeTitle, dockBadgeHelp
        case fileCountOne, fileCountFew, fileCountMany, statusShowChanges
        case segmentFiles, segmentChanges, changesHintBase, changesHintToBase, changesHintUncommitted, changesHintToUncommitted
        case openInEditorTab, copyRelativePath, taskArchived, undoArchive, keepAwakeShort
        case archiveAnyway, archiveFailed, restoreFailed, orphanKept, branchGone, branchGoneInfo, restoreWithoutWorktree
        case baseMissing, baseMissingUnknown, noChanges, statusTruncated, filesTruncated, gitFailed, inspectorNoTask
        case diffBinary, diffTooLarge, diffModeChange, diffRenamedFrom, diffNotChanged, diffNotAFile, diffTabHelp
        case hostPausedBar, integrationNotInstalled, integrationShortInstalled, integrationShortOutdated, removeEllipsis, addLocalProject, addRemoteProject, hostConnected, hostConnecting, hostReconnecting, hostUnreachable, hostDisconnected, hostPaused
        case reconnect, checkServer, disconnect, remoteProjectTitle, hostLabel, pathLabel, hostPlaceholder, connect
        case add, remotePathMissing, serverTitle, toolFound, toolMissing, toolOptional, toolOutdated, socketClient
        case installPlanTitle, install, installManual, allInstalled, sudoHint, noStatusClient, forwardFailed, sshAuthFailed
        case remoteIntegration, unsupportedShell, installFailed, close, hostGaveUp, integrationNeedsRemote, folderEmpty, noGitFiles, optionalToolsLabel
        case archiveToggleHelp, showFiles, hostsMenuHelp, refreshLimitsHelp
        case worktreeRootHint, worktreeCopy, worktreeCopyHelp, setupCommand, setupCommandHelp, setupCommandSuggested, afterCreate, afterCreateSuggestedHelp, copyingEntry, copyFailed
        case connectToHost, connectHostTitle, openTerminal, closeTerminal, hostTerminal, plainSSHHint
        case editorLargeReadOnly, editorTooLarge, editorBinary, editorMissing, editorReadFailed, editorSaveFailed
        case editorConflict, editorReload, editorKeepMine, editorUnsavedTitle, editorUnsavedInfo, editorDontSave
        case diffInline, diffSideBySide, editorMinimap, editorUnsavedQuit
        case editorMenuDefinition, editorMenuReferences, editorMenuRename, editorMenuFormat, editorMenuComment
        case editorMenuCut, editorMenuCopy, editorMenuPaste
        case editorRenameOtherFiles, editorRenameRefused, editorPaletteTitle, editorRainbowTitle, editorTodoTitle, editorDependencyReadOnly, tsReady, tsLoading, tsStopped, tsNoTypeScript, tsNoNode, tsNotConnected, tsTooltip, tsUnavailableTip
        case paletteSearch, paletteTasks, paletteFiles, paletteCommands, paletteEmpty, paletteLoading, cmdQuickOpen, cmdCommandPalette
        case cmdArchiveTask, cmdPrevTask, cmdNextTask, cmdPrevTab, cmdNextTab, cmdToggleSidebar, cmdToggleInspector
        case cmdNewTab, cmdCloseTab, cmdShowFiles, cmdShowChanges, cmdLimits, cmdAttentionOnly
        // Window status bar (redesign v1 §7)
        case thisMac, workingOne, workingFew, workingMany, waitingOne, waitingFew, waitingMany, failedOne, failedFew, failedMany, limitedOne, limitedFew, limitedMany
        case paneOne, paneFew, paneMany, statusMachineHelp, statusNextWorkingHelp, statusPanesHelp
        case agentCountOne, agentCountFew, agentCountMany, subagentCountOne, subagentCountFew, subagentCountMany
        case tabCountOne, tabCountFew, tabCountMany, noAgents, rowWaiting, sessionsView, sessionsViewHelp
        case segmentGit, showGit, gitBranches, gitLocal, gitRemote, gitFetchHelp, gitSearch, gitAllBranches, gitAuthor, gitAllAuthors
        case gitFindAuthor, gitDate, gitAnyDate, gitToday, gitWeek, gitMonth, gitPath, gitPathPlaceholder, gitAnyPath, gitCommit
        case gitCommits, gitCopyHash, gitParents, gitNoCommits, gitNothingFound, gitYesterday, gitTodayAt, gitYesterdayAt
        case gitResizeHelp, gitAheadBehind, gitClearFilter, gitFound, gitFoundMore
        case sessionsNoMatch, sessionsTitle, sessionsClosed, sessionsConversations, sessionsToday, sessionsYesterday, sessionsYesterdayAt
        case sessionsSearch, sessionsAll, sessionsOpen, sessionsGo, sessionsMarkerOpen, sessionsMarkerClosed
        case sessionsNoSession, sessionsMessages, sessionsSplit, sessionsNoClosed, sessionsNoConversations, sessionsLoading
        case sessionsOffline, sessionsUntitled, sessionsProjectHelp, sessionsTabOne, sessionsTabFew, sessionsTabMany
        case sessionsClosedOne, sessionsClosedFew, sessionsClosedMany, sessionsConvOne, sessionsConvFew, sessionsConvMany
    }

    // «Сессии» (⌘Y)
    static var sessionsTitle: String { s(.sessionsTitle) }
    static var sessionsClosed: String { s(.sessionsClosed) }
    static var sessionsConversations: String { s(.sessionsConversations) }
    static var sessionsToday: String { s(.sessionsToday) }
    static var sessionsYesterday: String { s(.sessionsYesterday) }
    static func sessionsYesterdayAt(_ time: String) -> String { f(.sessionsYesterdayAt, time) }
    static var sessionsSearch: String { s(.sessionsSearch) }
    static var sessionsAll: String { s(.sessionsAll) }
    static var sessionsOpen: String { s(.sessionsOpen) }
    static var sessionsGo: String { s(.sessionsGo) }
    static var sessionsMarkerOpen: String { s(.sessionsMarkerOpen) }
    static var sessionsMarkerClosed: String { s(.sessionsMarkerClosed) }
    static var sessionsNoSession: String { s(.sessionsNoSession) }
    static func sessionsMessages(_ n: Int) -> String { f(.sessionsMessages, Int32(clamping: n)) }
    static var sessionsSplit: String { s(.sessionsSplit) }
    static var sessionsNoClosed: String { s(.sessionsNoClosed) }
    static var sessionsNoMatch: String { s(.sessionsNoMatch) }
    static var sessionsNoConversations: String { s(.sessionsNoConversations) }
    static var sessionsLoading: String { s(.sessionsLoading) }
    static func sessionsOffline(_ host: String) -> String { f(.sessionsOffline, host) }
    static var sessionsUntitled: String { s(.sessionsUntitled) }
    static var sessionsProjectHelp: String { s(.sessionsProjectHelp) }
    static func sessionsTabs(_ n: Int) -> String { count(n, .sessionsTabOne, .sessionsTabFew, .sessionsTabMany) }
    static func sessionsClosedCount(_ n: Int) -> String { count(n, .sessionsClosedOne, .sessionsClosedFew, .sessionsClosedMany) }
    static func sessionsConversationCount(_ n: Int) -> String { count(n, .sessionsConvOne, .sessionsConvFew, .sessionsConvMany) }


    /// Every tooltip of a clickable (icons-v2.html): «Действие — ⌥⌘I», or the action alone without a key.
    static func help(_ title: String, _ shortcut: Shortcut?) -> String {
        shortcut.map { "\(title) — \($0.label)" } ?? title
    }

    // Sidebar
    static var sectionPinned: String { s(.sectionPinned) }
    static var sectionProjects: String { s(.sectionProjects) }
    static var sectionArchived: String { s(.sectionArchived) }
    static var sectionSSHHosts: String { s(.sectionSSHHosts) }
    static var newTask: String { s(.newTask) }
    static var newTaskHelp: String { s(.newTaskHelp) }
    static var archiveToggleHelp: String { s(.archiveToggleHelp) }
    static var hostsMenuHelp: String { s(.hostsMenuHelp) }
    static func newTaskIn(_ project: String) -> String { f(.newTaskIn, project) }
    static var addProject: String { s(.addProject) }
    static var addProjectEllipsis: String { s(.addProjectEllipsis) }
    static var restore: String { s(.restore) }
    static var rename: String { s(.rename) }
    static var pin: String { s(.pin) }
    static var unpin: String { s(.unpin) }
    static var archive: String { s(.archive) }
    static var folderMissing: String { s(.folderMissing) }
    static func statusLabel(_ state: AgentState) -> String {
        switch state {
        case .working: s(.statusWorking)
        case .waiting: s(.statusWaiting)
        case .done: s(.statusDone)
        case .failed: s(.statusFailed)
        case .idle: s(.statusIdle)
        case .limit: s(.statusLimit)
        }
    }
    /// «лимит · до 20:20»: the state word with the reset time.
    static func limitUntil(_ clock: String) -> String { f(.limitUntil, clock) }
    static func rowWithStatus(_ name: String, _ state: AgentState) -> String { f(.rowWithStatus, name, statusLabel(state)) }
    static func folderMissing(_ path: String) -> String { f(.folderMissingPath, path) }
    static func hostNotConnected(_ host: String) -> String { f(.hostNotConnected, host) }
    static func hostOffline(_ host: String) -> String { f(.hostOffline, host) }
    static var remoteNoGit: String { s(.remoteNoGit) }
    static var sessionDetached: String { s(.sessionDetached) }
    static var more: String { s(.more) }
    static var settings: String { s(.settings) }
    static var settingsHelp: String { s(.settingsHelp) }
    static var settingsEllipsis: String { s(.settingsEllipsis) }
    static var collapseSidebarHelp: String { s(.collapseSidebarHelp) }
    static var expandSidebarHelp: String { s(.expandSidebarHelp) }

    // Title bar, tabs, new-task sheet
    static var inspectorHelp: String { s(.inspectorHelp) }
    static var diffUnavailable: String { s(.diffUnavailable) }
    static var newTabHelp: String { s(.newTabHelp) }
    static var closeTabHelp: String { s(.closeTabHelp) }
    static var allTabsHelp: String { s(.allTabsHelp) }
    static var taskNamePlaceholder: String { s(.taskNamePlaceholder) }
    static func firstMessagePlaceholder(_ agent: String) -> String { f(.firstMessagePlaceholder, agent) }
    static var escCancel: String { s(.escCancel) }
    static var cancel: String { s(.cancel) }
    static var create: String { s(.create) }
    static var branchRequired: String { s(.branchRequired) }
    static var branchInvalid: String { s(.branchInvalid) }
    static func branchExists(_ name: String) -> String { f(.branchExists, name) }
    static var fetchFailed: String { s(.fetchFailed) }
    static var createWithoutFetch: String { s(.createWithoutFetch) }
    static var fetchCancelled: String { s(.fetchCancelled) }
    static var noCommits: String { s(.noCommits) }
    static var worktreeLabel: String { s(.worktreeLabel) }
    static var worktreeOnHint: String { s(.worktreeOnHint) }
    static var worktreeOffHint: String { s(.worktreeOffHint) }
    static var fromBranch: String { s(.fromBranch) }
    static var newBranch: String { s(.newBranch) }
    static var fromName: String { s(.fromName) }
    static func currentBranch(_ name: String) -> String { f(.currentBranch, name) }
    static var refreshHelp: String { s(.refreshHelp) }
    static var searchBranches: String { s(.searchBranches) }
    static var branchesRemote: String { s(.branchesRemote) }
    static var branchesLocal: String { s(.branchesLocal) }
    static var branchDefault: String { s(.branchDefault) }
    static var branchTask: String { s(.branchTask) }
    static func updatedAgo(_ age: String) -> String { f(.updatedAgo, age) }
    static var justNow: String { s(.justNow) }
    static func minutesAgo(_ n: Int) -> String { f(.minutesAgo, n) }
    static func hoursAgo(_ n: Int) -> String { f(.hoursAgo, n) }
    static func daysAgo(_ n: Int) -> String { f(.daysAgo, n) }

    // Terminal area, alerts, menus
    static var configNotApplied: String { s(.configNotApplied) }
    static var usingDefaults: String { s(.usingDefaults) }
    static func launchFailed(_ error: String) -> String { f(.launchFailed, error) }
    static var terminalCreateFailed: String { s(.terminalCreateFailed) }
    static var exited: String { s(.exited) }
    static func exitedWithCode(_ code: Int32) -> String { f(.exitedWithCode, code) }
    static var relaunchHint: String { s(.relaunchHint) }
    static var emptyNoTask: String { s(.emptyNoTask) }
    static var emptyNoTabs: String { s(.emptyNoTabs) }
    public static func stateCorrupt(_ path: String) -> String { f(.stateCorrupt, path) }
    public static func stateUnreadable(_ path: String) -> String { f(.stateUnreadable, path) }

    /// Installed into GhosttyBridge (`TerminalSurfaceView.clipboardPromptText`) by the main window.
    static func clipboardPromptText() -> ClipboardPromptText {
        ClipboardPromptText(readClipboard: s(.clipboardRead), pasteUnsafe: s(.clipboardPasteUnsafe),
                            allow: s(.allow), cancel: cancel)
    }
    public static var ghosttyFailed: String { s(.ghosttyFailed) }
    public static var retry: String { s(.retry) }
    public static var quit: String { s(.quit) }
    static var menuHide: String { s(.menuHide) }
    static var menuQuit: String { s(.menuQuit) }
    static var menuEdit: String { s(.menuEdit) }
    static var undo: String { s(.undo) }
    static var redo: String { s(.redo) }
    static var cut: String { s(.cut) }
    static var copy: String { s(.copy) }
    static var paste: String { s(.paste) }
    static var selectAll: String { s(.selectAll) }

    // Settings
    static var languageTitle: String { s(.languageTitle) }
    static var languageSystem: String { s(.languageSystem) }
    static var languageRu: String { s(.languageRu) }
    static var languageEn: String { s(.languageEn) }
    static var defaultAgent: String { s(.defaultAgent) }
    static var editor: String { s(.editor) }
    static var externalEditor: String { s(.externalEditor) }
    static var externalEditorPlaceholder: String { s(.externalEditorPlaceholder) }
    static var terminalBackground: String { s(.terminalBackground) }
    static var backgroundTheme: String { s(.backgroundTheme) }
    static var afterRestart: String { s(.afterRestart) }
    static func saveFailed(_ error: String) -> String { f(.saveFailed, error) }
    static var notificationsTitle: String { s(.notificationsTitle) }
    static var limitNotificationsTitle: String { s(.limitNotificationsTitle) }
    static var toggleOn: String { s(.toggleOn) }
    static var toggleOff: String { s(.toggleOff) }
    static func agentWaiting(_ agent: String) -> String { f(.agentWaiting, agent) }
    static func agentDone(_ agent: String) -> String { f(.agentDone, agent) }
    static func agentsWorking(_ n: Int) -> String { f(.agentsWorking, n) }

    // Keep awake
    static var keepAwakeTitle: String { s(.keepAwakeTitle) }
    static var keepAwakeOffHelp: String { s(.keepAwakeOffHelp) }
    static var keepAwakeIdleHelp: String { s(.keepAwakeIdleHelp) }
    static func keepAwakeActiveHelp(_ n: Int) -> String { f(.keepAwakeActiveHelp, n) }
    static var keepAwakeGraceHelp: String { s(.keepAwakeGraceHelp) }
    /// ☕ tooltip: off / waiting for agents / how many work / the 2-min grace.
    static func keepAwakeHelp(enabled: Bool, held: Bool, working: Int) -> String {
        !enabled ? keepAwakeOffHelp : !held ? keepAwakeIdleHelp : working > 0 ? keepAwakeActiveHelp(working) : keepAwakeGraceHelp
    }
    static var agentsWorkingInfo: String { s(.agentsWorkingInfo) }

    // Integrations (Settings)
    static var integrationClaude: String { s(.integrationClaude) }
    static var integrationCodex: String { s(.integrationCodex) }
    static var integrationInstalled: String { s(.integrationInstalled) }
    static var integrationStatuslineByUser: String { s(.integrationStatuslineByUser) }
    static var integrationOutdated: String { s(.integrationOutdated) }
    static var hooksMissing: String { s(.hooksMissing) }
    static var codexNotifyMissing: String { s(.codexNotifyMissing) }
    static var installEllipsis: String { s(.installEllipsis) }
    static var updateEllipsis: String { s(.updateEllipsis) }
    static var removeIntegration: String { s(.removeIntegration) }
    static var codexNotFound: String { s(.codexNotFound) }
    static var codexLookup: String { s(.codexLookup) }
    static var integrationNeedsApp: String { s(.integrationNeedsApp) }
    static var integrationMCP: String { s(.integrationMCP) }
    static var copyCommand: String { s(.copyCommand) }
    static var commandCopied: String { s(.commandCopied) }
    static var mcpHint: String { s(.mcpHint) }
    static var dockBadgeTitle: String { s(.dockBadgeTitle) }
    static var dockBadgeHelp: String { s(.dockBadgeHelp) }
    static func settingsInvalidJSON(_ line: Int) -> String { f(.settingsInvalidJSON, line) }
    static var settingsUnsupported: String { s(.settingsUnsupported) }
    static var fileChanged: String { s(.fileChanged) }
    static var codexConfigUnsupported: String { s(.codexConfigUnsupported) }
    static func integrationWriteFailed(_ error: String) -> String { f(.integrationWriteFailed, error) }
    static func integrationConfirmTitle(_ path: String) -> String { f(.integrationConfirmTitle, path) }
    static func backupWillBeCreated(_ path: String) -> String { f(.backupWillBeCreated, path) }
    static func backupCreated(_ path: String) -> String { f(.backupCreated, path) }
    static func linesUnchanged(_ n: Int) -> String { f(.linesUnchanged, n) }
    static var apply: String { s(.apply) }
    static var moveToApplications: String { s(.moveToApplications) }
    static var integrationChecking: String { s(.integrationChecking) }

    // Subscription limits
    static var limitSession: String { s(.limitSession) }
    static var limitWeekAll: String { s(.limitWeekAll) }
    static var limitWeek: String { s(.limitWeek) }
    static func limitWeekModel(_ model: String) -> String { f(.limitWeekModel, model) }
    static func resetIn(_ duration: String, _ time: String) -> String { f(.resetIn, duration, time) }
    static func durationMin(_ m: Int) -> String { f(.durationMin, m) }
    static func durationHourMin(_ h: Int, _ m: Int) -> String { f(.durationHourMin, h, m) }
    static func durationDayHour(_ d: Int, _ h: Int) -> String { f(.durationDayHour, d, h) }
    static func limitAlmost(_ agent: String, _ percent: Int) -> String { f(.limitAlmost, agent, Int32(clamping: percent)) }
    static func limitReached(_ agent: String) -> String { f(.limitReached, agent) }
    static var limitBadgeAlmost: String { s(.limitBadgeAlmost) }
    static var limitBadgeFull: String { s(.limitBadgeFull) }
    static var limitsShortcutHint: String { s(.limitsShortcutHint) }
    static var refresh: String { s(.refresh) }
    static var limitsHelp: String { s(.limitsHelp) }
    static var refreshLimitsHelp: String { s(.refreshLimitsHelp) }

    // Actions (context menus), project settings
    static var revealInFinder: String { s(.revealInFinder) }
    static var copyPath: String { s(.copyPath) }
    static func portCopy(_ port: Int) -> String { f(.portCopy, String(port)) }  // %@: a port is never digit-grouped
    static var copyLink: String { s(.copyLink) }
    static var attentionOnly: String { s(.attentionOnly) }
    static var nobodyWaiting: String { s(.nobodyWaiting) }
    static func openIn(_ arg: String) -> String { f(.openIn, arg) }
    static func openFailed(_ arg: String) -> String { f(.openFailed, arg) }
    static var deletePermanently: String { s(.deletePermanently) }
    static func deleteTaskConfirm(_ arg: String) -> String { f(.deleteTaskConfirm, arg) }
    static var deleteTaskInfo: String { s(.deleteTaskInfo) }
    static var alsoDeleteWorktree: String { s(.alsoDeleteWorktree) }
    static var worktreeDirty: String { s(.worktreeDirty) }
    static var worktreeDirtyInfo: String { s(.worktreeDirtyInfo) }
    static var worktreeIgnored: String { s(.worktreeIgnored) }
    static func worktreeIgnoredInfo(_ files: String) -> String { f(.worktreeIgnoredInfo, files) }
    static var deleteAnyway: String { s(.deleteAnyway) }
    static var worktreeRemoveFailed: String { s(.worktreeRemoveFailed) }
    static func branchKept(_ name: String) -> String { f(.branchKept, name) }
    static var delete: String { s(.delete) }
    static var projectSettingsEllipsis: String { s(.projectSettingsEllipsis) }
    static var projectSettings: String { s(.projectSettings) }
    static var removeFromHangar: String { s(.removeFromHangar) }
    static func removeProjectConfirm(_ arg: String) -> String { f(.removeProjectConfirm, arg) }
    static var removeProjectInfo: String { s(.removeProjectInfo) }
    static var remove: String { s(.remove) }
    static var splitRight: String { s(.splitRight) }
    static var splitDown: String { s(.splitDown) }
    static var closeTab: String { s(.closeTab) }
    static var drawerTitle: String { s(.drawerTitle) }
    static var drawerToggle: String { s(.drawerToggle) }
    static var drawerHelp: String { s(.drawerHelp) }
    static var projectName: String { s(.projectName) }
    static var projectPath: String { s(.projectPath) }
    static var chooseEllipsis: String { s(.chooseEllipsis) }
    static var defaultBranch: String { s(.defaultBranch) }
    static var creatingWorktreeWait: String { s(.creatingWorktreeWait) }
    static var worktreeRootInsideProject: String { s(.worktreeRootInsideProject) }
    static var worktreeFolder: String { s(.worktreeFolder) }
    static func worktreeRootHint(_ folder: String) -> String { f(.worktreeRootHint, folder) }
    static var worktreeCopy: String { s(.worktreeCopy) }
    static var worktreeCopyHelp: String { s(.worktreeCopyHelp) }
    static var setupCommand: String { s(.setupCommand) }
    static var setupCommandHelp: String { s(.setupCommandHelp) }
    static var setupCommandSuggested: String { s(.setupCommandSuggested) }
    static var afterCreate: String { s(.afterCreate) }
    static var afterCreateSuggestedHelp: String { s(.afterCreateSuggestedHelp) }
    static func copyingEntry(_ entry: String) -> String { f(.copyingEntry, entry) }
    static func copyFailed(_ reason: String) -> String { f(.copyFailed, reason) }
    static var pathMustBeAbsolute: String { s(.pathMustBeAbsolute) }
    static func branchAuto(_ value: String) -> String { f(.branchAuto, value) }
    static var save: String { s(.save) }
    // Inspector (`%d` keys take Int32: String(format:) reads 32 bits)
    /// «1 файл / 2 файла / 5 файлов»; en has one/other only (few = many there).
    static func fileCount(_ n: Int) -> String { count(n, .fileCountOne, .fileCountFew, .fileCountMany) }
    static var statusShowChanges: String { s(.statusShowChanges) }
    // Window status bar: «1 работает», «3 ждут», «1 ошибка», «2 панели» (ru one/few/many; en one/other)
    static func workingCount(_ n: Int) -> String { count(n, .workingOne, .workingFew, .workingMany) }
    static func waitingCount(_ n: Int) -> String { count(n, .waitingOne, .waitingFew, .waitingMany) }
    static func failedCount(_ n: Int) -> String { count(n, .failedOne, .failedFew, .failedMany) }
    static func limitedCount(_ n: Int) -> String { count(n, .limitedOne, .limitedFew, .limitedMany) }
    static func paneCount(_ n: Int) -> String { count(n, .paneOne, .paneFew, .paneMany) }
    static var thisMac: String { s(.thisMac) }
    static var statusMachineHelp: String { s(.statusMachineHelp) }
    static var statusNextWorkingHelp: String { s(.statusNextWorkingHelp) }
    static var statusPanesHelp: String { s(.statusPanesHelp) }
    // Session rows (redesign v1): «ждёт · 1 агент», «работает · 2 субагента», «нет агентов · 1 вкладка»
    private static func count(_ n: Int, _ one: Key, _ few: Key, _ many: Key) -> String {
        let key: Key = switch pluralForm(n) {
        case .one: one
        case .few: few
        case .many: many
        }
        return f(key, Int32(clamping: n))
    }
    static func agentCount(_ n: Int) -> String { count(n, .agentCountOne, .agentCountFew, .agentCountMany) }
    static func subagentCount(_ n: Int) -> String { count(n, .subagentCountOne, .subagentCountFew, .subagentCountMany) }
    static func tabCount(_ n: Int) -> String { count(n, .tabCountOne, .tabCountFew, .tabCountMany) }
    static var noAgents: String { s(.noAgents) }
    /// The row's short state word: «ждёт», not the tab's «ждёт ответа».
    static func rowStatus(_ state: AgentState) -> String { state == .waiting ? s(.rowWaiting) : statusLabel(state) }
    static var sessionsView: String { s(.sessionsView) }
    static var sessionsViewHelp: String { s(.sessionsViewHelp) }
    static var showFiles: String { s(.showFiles) }
    static var segmentFiles: String { s(.segmentFiles) }
    static var openInEditorTab: String { s(.openInEditorTab) }
    static var copyRelativePath: String { s(.copyRelativePath) }
    static var taskArchived: String { s(.taskArchived) }
    static var undoArchive: String { s(.undoArchive) }
    static var archiveAnyway: String { s(.archiveAnyway) }
    static var archiveFailed: String { s(.archiveFailed) }
    static var restoreFailed: String { s(.restoreFailed) }
    static var orphanKept: String { s(.orphanKept) }
    static func branchGone(_ name: String) -> String { f(.branchGone, name) }
    static var branchGoneInfo: String { s(.branchGoneInfo) }
    static var restoreWithoutWorktree: String { s(.restoreWithoutWorktree) }
    static var keepAwakeShort: String { s(.keepAwakeShort) }
    static func segmentChanges(_ n: Int) -> String { f(.segmentChanges, Int32(clamping: n)) }
    static func changesHintBase(_ branch: String) -> String { f(.changesHintBase, branch) }
    static func changesHintToBase(_ branch: String) -> String { f(.changesHintToBase, branch) }
    static var changesHintUncommitted: String { s(.changesHintUncommitted) }
    static var changesHintToUncommitted: String { s(.changesHintToUncommitted) }
    static func baseMissing(_ branch: String) -> String { f(.baseMissing, branch) }
    static var baseMissingUnknown: String { s(.baseMissingUnknown) }
    static var noChanges: String { s(.noChanges) }
    static func statusTruncated(_ n: Int) -> String { f(.statusTruncated, Int32(clamping: n)) }
    static func filesTruncated(_ n: Int) -> String { f(.filesTruncated, Int32(clamping: n)) }
    static func gitFailed(_ message: String) -> String { f(.gitFailed, message) }
    static var inspectorNoTask: String { s(.inspectorNoTask) }

    // Git tab (redesign v1 §4)
    static var segmentGit: String { s(.segmentGit) }
    static var showGit: String { s(.showGit) }
    static var gitBranches: String { s(.gitBranches) }
    static var gitLocal: String { s(.gitLocal) }
    static var gitRemote: String { s(.gitRemote) }
    static var gitFetchHelp: String { s(.gitFetchHelp) }
    static var gitSearch: String { s(.gitSearch) }
    static var gitAllBranches: String { s(.gitAllBranches) }
    static var gitAuthor: String { s(.gitAuthor) }
    static var gitAllAuthors: String { s(.gitAllAuthors) }
    static var gitFindAuthor: String { s(.gitFindAuthor) }
    static var gitDate: String { s(.gitDate) }
    static var gitAnyDate: String { s(.gitAnyDate) }
    static func gitDateRange(_ r: GitDateRange) -> String {
        switch r {
        case .today: s(.gitToday)
        case .week: s(.gitWeek)
        case .month: s(.gitMonth)
        }
    }
    static var gitPath: String { s(.gitPath) }
    static var gitPathPlaceholder: String { s(.gitPathPlaceholder) }
    static var gitAnyPath: String { s(.gitAnyPath) }
    static var gitCommit: String { s(.gitCommit) }
    static var gitCommits: String { s(.gitCommits) }
    static var gitCopyHash: String { s(.gitCopyHash) }
    static func gitParents(_ n: Int) -> String { f(.gitParents, Int32(clamping: n)) }
    static var gitNoCommits: String { s(.gitNoCommits) }
    static var gitNothingFound: String { s(.gitNothingFound) }
    static var gitYesterday: String { s(.gitYesterday) }
    static func gitTodayAt(_ time: String) -> String { f(.gitTodayAt, time) }
    static func gitYesterdayAt(_ time: String) -> String { f(.gitYesterdayAt, time) }
    static var gitResizeHelp: String { s(.gitResizeHelp) }
    static func gitAheadBehind(_ ahead: Int, _ behind: Int, _ upstream: String) -> String {
        f(.gitAheadBehind, Int32(clamping: ahead), Int32(clamping: behind), upstream)
    }
    static var gitClearFilter: String { s(.gitClearFilter) }
    /// The search field's count: «3», or «200+» while more pages exist.
    static func gitFound(_ n: Int, more: Bool) -> String { f(more ? .gitFoundMore : .gitFound, Int32(clamping: n)) }
    // Diff tab
    static var diffBinary: String { s(.diffBinary) }
    static var editorLargeReadOnly: String { s(.editorLargeReadOnly) }
    static func editorTooLarge(_ bytes: Int64) -> String {
        f(.editorTooLarge, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
    static var editorBinary: String { s(.editorBinary) }
    static var editorMissing: String { s(.editorMissing) }
    static func editorReadFailed(_ message: String) -> String { f(.editorReadFailed, message) }
    static func editorSaveFailed(_ message: String) -> String { f(.editorSaveFailed, message) }
    static var editorConflict: String { s(.editorConflict) }
    static var editorReload: String { s(.editorReload) }
    static var editorKeepMine: String { s(.editorKeepMine) }
    static func editorUnsavedTitle(_ name: String) -> String { f(.editorUnsavedTitle, name) }
    static var editorUnsavedInfo: String { s(.editorUnsavedInfo) }
    static var editorDontSave: String { s(.editorDontSave) }
    static var diffInline: String { s(.diffInline) }
    static var diffSideBySide: String { s(.diffSideBySide) }
    static var editorMinimap: String { s(.editorMinimap) }
    /// The editor's context menu (#81), handed to the page by key.
    static var editorMenu: [String: String] {
        ["definition": s(.editorMenuDefinition), "references": s(.editorMenuReferences), "rename": s(.editorMenuRename),
         "format": s(.editorMenuFormat), "comment": s(.editorMenuComment), "cut": s(.editorMenuCut),
         "copy": s(.editorMenuCopy), "paste": s(.editorMenuPaste), "renameRefused": s(.editorRenameRefused)]
    }
    static func editorUnsavedQuit(_ n: Int) -> String { f(.editorUnsavedQuit, Int32(clamping: n)) }
    static var editorDependencyReadOnly: String { s(.editorDependencyReadOnly) }
    static var editorRenameOtherFiles: String { s(.editorRenameOtherFiles) }
    static var editorRenameRefused: String { s(.editorRenameRefused) }
    static var editorPaletteTitle: String { s(.editorPaletteTitle) }
    static var editorRainbowTitle: String { s(.editorRainbowTitle) }
    static var editorTodoTitle: String { s(.editorTodoTitle) }
    static func tsReady(_ version: String) -> String { f(.tsReady, version) }
    static func tsLoading(_ version: String) -> String { f(.tsLoading, version) }
    static var tsStopped: String { s(.tsStopped) }
    static var tsNoTypeScript: String { s(.tsNoTypeScript) }
    static var tsNoNode: String { s(.tsNoNode) }
    static var tsNotConnected: String { s(.tsNotConnected) }
    static func tsTooltip(_ tsserver: String, _ node: String) -> String { f(.tsTooltip, tsserver, node) }
    static var tsUnavailableTip: String { s(.tsUnavailableTip) }
    static func diffTooLarge(_ n: Int) -> String { f(.diffTooLarge, Int32(clamping: n)) }
    static func diffModeChange(_ old: String, _ new: String) -> String { f(.diffModeChange, old, new) }
    static func diffRenamedFrom(_ path: String) -> String { f(.diffRenamedFrom, path) }
    static var diffNotChanged: String { s(.diffNotChanged) }
    static var diffNotAFile: String { s(.diffNotAFile) }
    static var diffTabHelp: String { s(.diffTabHelp) }

    // SSH hosts, remote project and server sheets
    static var integrationNotInstalled: String { s(.integrationNotInstalled) }
    static func hostPausedBar(_ host: String) -> String { f(.hostPausedBar, host) }
    static var integrationShortInstalled: String { s(.integrationShortInstalled) }
    static var integrationShortOutdated: String { s(.integrationShortOutdated) }
    static var removeEllipsis: String { s(.removeEllipsis) }
    static var addLocalProject: String { s(.addLocalProject) }
    static var addRemoteProject: String { s(.addRemoteProject) }
    static var hostConnected: String { s(.hostConnected) }
    static var hostConnecting: String { s(.hostConnecting) }
    static var hostReconnecting: String { s(.hostReconnecting) }
    static var hostUnreachable: String { s(.hostUnreachable) }
    static var hostDisconnected: String { s(.hostDisconnected) }
    static var hostPaused: String { s(.hostPaused) }
    static var reconnect: String { s(.reconnect) }
    static var checkServer: String { s(.checkServer) }
    static var disconnect: String { s(.disconnect) }
    static var remoteProjectTitle: String { s(.remoteProjectTitle) }
    static var hostLabel: String { s(.hostLabel) }
    static var pathLabel: String { s(.pathLabel) }
    static var hostPlaceholder: String { s(.hostPlaceholder) }
    static var connect: String { s(.connect) }
    static var add: String { s(.add) }
    static var remotePathMissing: String { s(.remotePathMissing) }
    static func serverTitle(_ arg: String) -> String { f(.serverTitle, arg) }
    static func toolFound(_ arg: String) -> String { f(.toolFound, arg) }
    static var toolMissing: String { s(.toolMissing) }
    static var toolOptional: String { s(.toolOptional) }
    static func toolOutdated(_ arg: String) -> String { f(.toolOutdated, arg) }
    static var socketClient: String { s(.socketClient) }
    static var installPlanTitle: String { s(.installPlanTitle) }
    static var install: String { s(.install) }
    static func installManual(_ arg: String) -> String { f(.installManual, arg) }
    static var allInstalled: String { s(.allInstalled) }
    static var sudoHint: String { s(.sudoHint) }
    static var noStatusClient: String { s(.noStatusClient) }
    static var forwardFailed: String { s(.forwardFailed) }
    static func sshAuthFailed(_ arg: String) -> String { f(.sshAuthFailed, arg) }
    static func remoteIntegration(_ arg: String) -> String { f(.remoteIntegration, arg) }
    static func unsupportedShell(_ arg: String) -> String { f(.unsupportedShell, arg) }
    static func installFailed(_ code: Int32) -> String { f(.installFailed, code) }
    static var close: String { s(.close) }
    static func hostGaveUp(_ arg: String) -> String { f(.hostGaveUp, arg) }
    static var integrationNeedsRemote: String { s(.integrationNeedsRemote) }
    static var folderEmpty: String { s(.folderEmpty) }
    static var noGitFiles: String { s(.noGitFiles) }
    static var optionalToolsLabel: String { s(.optionalToolsLabel) }
    // «<host> · терминал» (#64)
    static var connectToHost: String { s(.connectToHost) }
    static var connectHostTitle: String { s(.connectHostTitle) }
    static var openTerminal: String { s(.openTerminal) }
    static var closeTerminal: String { s(.closeTerminal) }
    static func hostTerminal(_ host: String) -> String { f(.hostTerminal, host) }
    static var plainSSHHint: String { s(.plainSSHHint) }

    public static var ok: String { s(.ok) }
    static func exitStatus(_ code: Int32) -> String { f(.exitStatus, code) }

    // ⌘P quick open / ⇧⌘P command palette
    static var paletteSearch: String { s(.paletteSearch) }
    static var paletteEmpty: String { s(.paletteEmpty) }
    static var paletteLoading: String { s(.paletteLoading) }
    static func paletteSection(_ kind: PaletteItem.Kind) -> String {
        switch kind {
        case .task: s(.paletteTasks)
        case .file: s(.paletteFiles)
        case .command: s(.paletteCommands)
        }
    }
    /// Palette title of a menu command (`paletteCommands`); the menus' own wording where there is one (en: Title Case).
    static func command(_ sc: Shortcut) -> String {
        switch sc {
        case .newTask: newTask
        case .addProject: addProject
        case .newTab: s(.cmdNewTab)
        case .closeTab: s(.cmdCloseTab)
        case .splitRight: s(.splitRight)
        case .splitDown: s(.splitDown)
        case .archiveTask: s(.cmdArchiveTask)
        case .rename: rename
        case .prevTask: s(.cmdPrevTask)
        case .nextTask: s(.cmdNextTask)
        case .prevTab: s(.cmdPrevTab)
        case .nextTab: s(.cmdNextTab)
        case .toggleSidebar: s(.cmdToggleSidebar)
        case .toggleInspector: s(.cmdToggleInspector)
        case .inspectorFiles: s(.cmdShowFiles)
        case .inspectorChanges: s(.cmdShowChanges)
        case .inspectorGit: showGit
        case .toggleDrawer: s(.drawerToggle)
        case .limits: s(.cmdLimits)
        case .revealInFinder: s(.revealInFinder)
        case .copyPath: s(.copyPath)
        case .settings: settings
        case .quickOpen: s(.cmdQuickOpen)
        case .commandPalette: s(.cmdCommandPalette)
        case .attentionFilter: s(.cmdAttentionOnly)
        case .sessions: sessionsTitle
        case .tab(let n): "\(n)"
        case .focusSplit: ""
        }
    }
}
