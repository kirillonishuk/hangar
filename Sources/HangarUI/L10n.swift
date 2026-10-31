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
        language.resolved(preferred: preferred)
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

    static func f(_ key: Key, _ args: CVarArg...) -> String {
        String(format: s(key), locale: Locale(identifier: resolve(language).rawValue), arguments: args)
    }

    nonisolated enum Key: String, CaseIterable, Sendable {
        case sectionPinned, sectionProjects, sectionArchived, sectionSSHHosts, newTask, newTaskHelp
        case newTaskIn, addProject, addProjectEllipsis, restore, rename
        case pin, unpin, archive, folderMissing
        case statusWorking, statusWaiting, statusDone, statusFailed, statusIdle, statusLimit, limitUntil, rowWithStatus
        case folderMissingPath, more, settings, settingsHelp, settingsEllipsis
        case collapseSidebarHelp, expandSidebarHelp, inspectorHelp, diffUnavailable, newTabHelp, closeTabHelp, allTabsHelp
        case taskNamePlaceholder, escCancel, cancel, create, configNotApplied
        case usingDefaults, launchFailed, terminalCreateFailed, exited, exitedWithCode, relaunchHint, hostNotConnected, hostOffline, remoteNoGit, sessionDetached, conversationNotLinked
        case emptyNoTask, emptyNoTabs, terminalTab, ghosttyFailed, retry, quit, menuHide
        case menuQuit, menuEdit, undo, redo, cut, copy
        case paste, selectAll, languageTitle, languageSystem, languageRu, languageEn
        case dropRight, dropLeft, dropUp, dropDown, paneNew, paneEditorCap, continueTitle, closePane, detachPane, paneAgentWorking, paneAgentWorkingInfo, tabAgentWorkingInfo, defaultAgent, defaultAgentHint, editor, externalEditor, externalEditorHint, externalEditorPlaceholder, updatesSection, inboxTitle, inboxEmpty, emptyNoProject
        case appearance, themeTitle, themeGraphite, saveFailed
        case settingsGeneral, settingsNotifications, settingsIntegrations, settingsAdvanced, configFile, showInFinder
        case pillInstalled, pillMissing, pillOutdated, pillUnavailable, pillChecking, pillError, sectionProjectTitle, sectionToolsTitle
        case notificationsTitle, limitNotificationsTitle, toggleOn, toggleOff, agentPermission, agentQuestion, agentDone, agentFailed, agentLimit
        case noticeOpen, noticeAllow, noticeReply, noticeOpenLimits
        case notifyPermissionTitle, notifyQuestionTitle, notifyDoneTitle, notifyFailedTitle, soundTitle, soundNone, soundDefault
        case allowFromNotificationTitle, allowFromNotificationHelp, notifyWhenActiveTitle, notifyWhenActiveHelp, sshTerminalBellTitle, sshTerminalBellHelp
        case notificationPermissionTitle, notificationsAllowedInSystem, notificationsNotAsked, notificationsDeniedInSystem, openSystemSettings
        case urgentNotice, muteSession, unmuteSession, projectNotificationsAll, projectNotificationsUrgent, projectNotificationsOff
        case projectNotificationsTitle, notifySegmentAll, notifySegmentUrgent, notifySegmentOff, mutedSessionHelp
        case revealInFinder, copyPath, portCopy, openIn, openFailed, deletePermanently, deleteTaskConfirm, deleteTaskInfo, delete
        case copyLink, linkNotFound, attentionOnly, nobodyWaiting, inbox, inboxRecentDone, inboxDismiss, inboxClear, cmdNextAttention
        case alsoDeleteWorktree, worktreeDirty, worktreeDirtyInfo, worktreeIgnored, worktreeIgnoredInfo, deleteAnyway, worktreeRemoveFailed, branchKept
        case projectSettingsEllipsis, projectSettings, removeFromHangar, removeProjectConfirm, removeProjectInfo, remove, splitRight, splitDown
        case drawerTitle, drawerToggle, drawerHelp
        case closeTab, projectName, projectPath, chooseEllipsis, defaultBranch, worktreeFolder, creatingWorktreeWait, worktreeRootInsideProject, worktreesInsideNotice, keepWorktreesBeside, keepWorktreesBesideHelp, pathMustBeAbsolute, branchAuto, save
        case ok, exitStatus, stateCorrupt, stateUnreadable
        case clipboardRead, clipboardPasteUnsafe, allow
        case branchRequired, branchInvalid, branchExists, fetchFailed, createWithoutFetch, fetchCancelled, noCommits
        case branchDirty, branchDirtyHint, branchDirtyNewHint, branchCheckedOutInChat, branchCheckedOutAt, branchIgnoredOverwrite, branchOperationInProgress
        case worktreeLabel, newBranch, refreshHelp
        case whereToWork, whereFolder, whereFolderBranch, whereFolderCommit, whereFolderShared, whereCopy, whereCopyHint
        case copyNeedsCommit, branchFrom, taskFor, taskLater, chatNumbered, createHelp
        case searchBranches, branchesRemote, branchesLocal, branchDefault, branchTask
        case switcherSearch, switcherLocal, switcherRemote, branchCurrent, branchInChatNote, branchInFolderNote, branchNewFrom, branchCreate, branchCreateNamed
        case branchNamePrompt, branchFromCurrent, branchSwitching, branchCreating, branchesLoading, branchSwitchHint
        case branchDirtyRepo, branchSwitched, branchCreated
        case updatedAgo, justNow, minutesAgo, hoursAgo, daysAgo
        case agentsWorking, agentsWorkingInfo
        case keepAwakeTitle
        case keepAwakeOffHelp, keepAwakeIdleHelp, keepAwakeActiveHelp, keepAwakeGraceHelp
        case limitSession, limitSessionShort, limitWeekShort, limitNoData, limitWeekAll, limitWeek, limitWeekModel, resetIn, durationMin, durationHourMin, durationDayHour, durationUnderMin, durationHour
        case limitAlmost, limitReached, limitBadgeAlmost, limitBadgeFull, limitsShortcutHint, refresh, limitsHelp
        case integrationClaude, integrationCodex, integrationInstalled, integrationStatuslineByUser, integrationOutdated
        case hooksMissing, codexNotifyMissing, installEllipsis, updateEllipsis, removeIntegration, codexNotFound, codexLookup
        case integrationNeedsApp, settingsInvalidJSON, settingsUnsupported, fileChanged, codexConfigUnsupported, integrationWriteFailed
        case integrationConfirmTitle, backupWillBeCreated, backupCreated, linesUnchanged, apply, moveToApplications, integrationChecking
        case integrationMCP, copyCommand, commandCopied, mcpHint, dockBadgeTitle, dockBadgeHelp
        case fileCountOne, fileCountFew, fileCountMany, statusShowChanges
        case segmentFiles, segmentChanges, segmentChangesTitle, changesWholeBranch, changesHintToBase, changesHintUncommitted, changesHintToUncommitted
        case openInEditorTab, copyRelativePath, taskArchived, undoArchive, keepAwakeShort
        case archiveAnyway, archiveFailed, restoreFailed, orphanKept, branchGone, branchGoneInfo, restoreWithoutWorktree
        case baseMissing, baseMissingUnknown, noChanges, statusTruncated, filesTruncated, gitFailed, inspectorHostShell
        case diffBinary, diffTooLarge, diffModeChange, diffRenamedFrom, diffNotChanged, diffNotAFile, diffTabHelp, diffNoChanges, diffChangeCounter, diffPrevChange, diffNextChange
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
        case edCustom, edAsTheme, edHintTheme, edHintCustom, edHintCustomSame, edResetAll, edColors, edSyntax, edCreated, edAllReset, edReplaceTitle, edReplaceInfo, edReplace, edReset, edResetTo, edThemeColors, edSystemPalette, edHue, edLightness, edOpacity, edFontSection, edIndentSection, edViewSection, edFont, edSize, edLineHeight, edLigatures, edTabSize, edDetect, edWrap, edLineHighlight, edCursor, edBlink, edWhitespace, edBracketColors, edBracketGuides, edIndentGuides, edFormatOnSave, edSystemFont, edPt, edLineAuto, edAuto, edSmaller, edLarger, edWrapOff, edWrapOn, edLhNone, edLhGutter, edLhLine, edLhAll, edCursorLine, edCursorBlock, edCursorUnderline, edBlinkBlink, edBlinkSmooth, edBlinkSolid, edWsNone, edWsSelection, edWsAll, edGuidesNone, edGuidesActive, edGuidesAll, edDetectTip, edFormatTip, edLineHeightTip, edLigaturesTip, edcKeyword, edcControl, edcString, edcEscape, edcRegexp, edcComment, edcNumber, edcType, edcFunction, edcVariable, edcConstant, edcJsonKey, edcPunctuation, edcOperator, edcText, edcBackground, edcLine, edcSelection, edcFind, edcGutter, edcGutterActive, edcCursor, edcIndent, edcIndentActive, edcWhitespace, edcBrackets, edcBracket1, edcBracket2, edcBracket3, edcDiffAddedLine, edcDiffRemovedLine, edcDiffAddedText, edcDiffRemovedText, edsKeyword, edsControl, edsString, edsEscape, edsComment, edsNumber, edsType, edsFunction, edsVariable, edsConstant, edsJsonKey, edsPunctuation, edsOperator, edsText
        case editorRenameOtherFiles, editorRenameRefused, editorRainbowTitle, editorTodoTitle, editorDependencyReadOnly, tsReady, tsLoading, tsStopped, tsNoTypeScript, tsNoNode, tsNotConnected, tsTooltip, tsUnavailableTip, lspLoading, lspStopped, lspMissing, lspMissingTip, lspTooltip, lspSection, lspInstalledFrom, lspNotInstalled, lspFromProject, lspSourceProject, lspTsDetail, lspNeedsXcode, lspXcodeTip, lspNeedsNode, lspNeedsGo, lspDownload, lspDownloadTip, lspRemove, lspRetry, lspDownloading, lspInstalling, lspToolFailed, lspNoAsset, lspDownloadFailed, lspNotOwned, lspNoExecutable, lspNotExecutable, downloadTooLarge
        case paletteSearch, paletteTasks, paletteFiles, paletteCommands, paletteEmpty, paletteLoading, cmdQuickOpen, cmdCommandPalette
        case cmdArchiveTask, cmdPrevTask, cmdNextTask, cmdPrevTab, cmdNextTab, cmdToggleSidebar, cmdToggleInspector
        case cmdNewTab, cmdCloseTab, cmdShowFiles, cmdShowChanges, cmdLimits, cmdAttentionOnly
        case thisMac, notifySectionEvents, notifySectionSystem, cmdNextWorking
        case updateTo, updateAvailableHelp, updateSheetTitle, updateCurrent, updateNoNotes, updateInstall, updateRestart
        case updateLater, updateSkip, updateDownloading, updateDownloadingPlain, updatePreparing, updateReady, updateQuitHint
        case updateManual, updateFailed, updateInstallFailed, updateChecksumMismatch, updateWrongApp, updateOpenPage
        case checkUpdatesTitle, versionTitle, checkNow, updateChecking, updateUpToDate, updateCheckFailed, updateDevBuild
        case updateOtherInstance, updateUntrusted, updateBadSignature
        case agentCountOne, agentCountFew, agentCountMany, subagentCountOne, subagentCountFew, subagentCountMany
        case tabCountOne, tabCountFew, tabCountMany, noAgents, rowWaiting, sessionsViewHelp
        case segmentGit, showGit, gitBranch, gitBranches, gitLocal, gitRemote, gitFetchHelp, gitSearch, gitAllBranches, gitAuthor, gitAllAuthors
        case gitFindAuthor, gitDate, gitAnyDate, gitToday, gitWeek, gitMonth, gitPath, gitPathPlaceholder, gitAnyPath, gitCommit
        case gitCommits, gitCopyHash, gitParents, gitNoCommits, gitNothingFound, gitYesterday, gitTodayAt, gitYesterdayAt
        case gitResizeHelp, gitAheadBehind, gitClearFilter, gitFound, gitFoundMore, opensMenu
        case sessionsNoMatch, sessionsTitle, sessionsYesterday, sessionsSearch, sessionsAll, sessionsGo, sessionsMarkerOpen
        case sessionsMessages, sessionsLoading, sessionsOffline, sessionsUntitled, sessionsTabOne, sessionsTabFew, sessionsTabMany
        case sessionsMore, sessionsMarkerArchived, sessionsMarkerHistory, sessionsChipOpen, sessionsChipArchived, sessionsChipHistory
        case sessionsReset, sessionsResetFilters, sessionsShowMore, sessionsReadingHost, sessionsHostTimedOut, sessionsHostFailed
        case sessionsOfflineHint, sessionsConnect, sessionsEmpty, sessionsNoMatchQuery, sessionsHelpSession, sessionsArchivedHelp
        case sessionsArchivedSince, sessionsContinueIn, sessionsContinueNew, sessionsRestoreHelp, sessionsProjectChip, sessionsProjectChipHelp
        case sessionsLoadFailedLocal, projectSessions, sessionsContinue, sessionsTimedOut, sessionsUnknownError, projectArchive
        case segmentSearch, cmdFindInFiles, searchPlaceholder, searchInclude, searchExclude, searchFilters, searchFiltersOn, searchCase, searchRegex, searchWord
        case searchClear, searchRunning, searchNothing, searchFailed, searchTruncated, searchFileTruncated
        case searchSkippedOne, searchSkippedFew, searchSkippedMany
        case searchMatchOne, searchMatchFew, searchMatchMany, searchInFilesOne, searchInFilesFew, searchInFilesMany
        case statuslineTitle, statuslineShow, statuslineHangar, statuslineUser, statuslineHangarHelp, statuslineUserHelp, statuslineNoOwnHelp
        case statuslinePreview, statuslineUserPreview, statuslineParts, statuslineNeedsIntegration, statuslineChipHelp, statuslineMoveLeft, statuslineMoveRight
        case statuslineSegModel, statuslineSegContext, statuslineSegFiveHour, statuslineSegWeek, statuslineSegBranch, statuslineSegEffort
        case statuslineProjects, statuslineProjectsHelp, statuslineOverridden, statuslineNotIgnored, statuslineFailed, fileReadOnly
        // Integrations by function (#111)
        case intOtherCopy, intRemoteMissing, intHooksTitle, intHooksClaudeSub, intHooksCodexSub, intLimitsTitle, intLimitsSub, intStatuslineTitle, intStatuslineSub, intStatuslineSheetTitle, intStatuslineSheetSub, intMCPSub, intMCPSheetSub, intThisMacTag, intThisMacTagHelp, intWhereInstalled, intWhereTo, intThisMac, intOffline, intOnConnect, intConnectEllipsis, intNoAgentOnHost, intSkipped, intFailed, intTipUpdated, intTipCurrent, intTipBackup, intTipOffline, intTipUndecided, intTipSkipped, intTipFailed, intTipNoAgent, intNotFound, intAgentNotFound, intMCPForeign, intMCPOtherCopy, intMCPFailed, intMCPUnreadable, intMCPMissing, intSheetTitle, intSheetSubtitle, intWhatChanges, intHideChanges, intNoChanges, intNotNow, intConnect, intHostTitle, intHostSubtitle, intHostSkip, intHostRemote, intPartHooks, intPartLimits, intPartStatusline, intNothingOn, intAgentOffHelp, intMCPNote, awaitingIntegrationAnswer
    }


    // Integrations by function (#111)
    static var intOtherCopy: String { s(.intOtherCopy) }
    static var intRemoteMissing: String { s(.intRemoteMissing) }
    static var intHooksTitle: String { s(.intHooksTitle) }
    static var intHooksClaudeSub: String { s(.intHooksClaudeSub) }
    static var intHooksCodexSub: String { s(.intHooksCodexSub) }
    static var intLimitsTitle: String { s(.intLimitsTitle) }
    static var intLimitsSub: String { s(.intLimitsSub) }
    static var intStatuslineTitle: String { s(.intStatuslineTitle) }
    static var intStatuslineSub: String { s(.intStatuslineSub) }
    static var intStatuslineSheetTitle: String { s(.intStatuslineSheetTitle) }
    static var intStatuslineSheetSub: String { s(.intStatuslineSheetSub) }
    static var intMCPSub: String { s(.intMCPSub) }
    static var intMCPSheetSub: String { s(.intMCPSheetSub) }
    static var intThisMacTag: String { s(.intThisMacTag) }
    static var intThisMacTagHelp: String { s(.intThisMacTagHelp) }
    static var intWhereInstalled: String { s(.intWhereInstalled) }
    static var intWhereTo: String { s(.intWhereTo) }
    static var intThisMac: String { s(.intThisMac) }
    static var intOffline: String { s(.intOffline) }
    static var intOnConnect: String { s(.intOnConnect) }
    static var intConnectEllipsis: String { s(.intConnectEllipsis) }
    static func intNoAgentOnHost(_ a: String) -> String { f(.intNoAgentOnHost, a) }
    static var intSkipped: String { s(.intSkipped) }
    static var intFailed: String { s(.intFailed) }
    static func intTipUpdated(_ a: String) -> String { f(.intTipUpdated, a) }
    static var intTipCurrent: String { s(.intTipCurrent) }
    static func intTipBackup(_ a: String) -> String { f(.intTipBackup, a) }
    static var intTipOffline: String { s(.intTipOffline) }
    static var intTipUndecided: String { s(.intTipUndecided) }
    static var intTipSkipped: String { s(.intTipSkipped) }
    static func intTipFailed(_ a: String) -> String { f(.intTipFailed, a) }
    static func intTipNoAgent(_ a: String) -> String { f(.intTipNoAgent, a) }
    static var intNotFound: String { s(.intNotFound) }
    static func intAgentNotFound(_ a: String, _ b: String) -> String { f(.intAgentNotFound, a, b) }
    static var intMCPForeign: String { s(.intMCPForeign) }
    static var intMCPOtherCopy: String { s(.intMCPOtherCopy) }
    static func intMCPFailed(_ a: String) -> String { f(.intMCPFailed, a) }
    static var intMCPUnreadable: String { s(.intMCPUnreadable) }
    static var intMCPMissing: String { s(.intMCPMissing) }
    static func intSheetTitle(_ a: String) -> String { f(.intSheetTitle, a) }
    static var intSheetSubtitle: String { s(.intSheetSubtitle) }
    static var intWhatChanges: String { s(.intWhatChanges) }
    static var intHideChanges: String { s(.intHideChanges) }
    static var intNoChanges: String { s(.intNoChanges) }
    static var intNotNow: String { s(.intNotNow) }
    static var intConnect: String { s(.intConnect) }
    static func intHostTitle(_ a: String) -> String { f(.intHostTitle, a) }
    static var intHostSubtitle: String { s(.intHostSubtitle) }
    static var intHostSkip: String { s(.intHostSkip) }
    static var intHostRemote: String { s(.intHostRemote) }
    static var intPartHooks: String { s(.intPartHooks) }
    static var intPartLimits: String { s(.intPartLimits) }
    static var intPartStatusline: String { s(.intPartStatusline) }
    static var intNothingOn: String { s(.intNothingOn) }
    static var intAgentOffHelp: String { s(.intAgentOffHelp) }
    static var intMCPNote: String { s(.intMCPNote) }
    static var awaitingIntegrationAnswer: String { s(.awaitingIntegrationAnswer) }

    // Search tab (find in files, #91)
    static var segmentSearch: String { s(.segmentSearch) }
    static var findInFiles: String { s(.cmdFindInFiles) }
    static var searchPlaceholder: String { s(.searchPlaceholder) }
    static var searchInclude: String { s(.searchInclude) }
    static var searchExclude: String { s(.searchExclude) }
    static var searchFilters: String { s(.searchFilters) }
    static var searchFiltersOn: String { s(.searchFiltersOn) }
    static var searchCase: String { s(.searchCase) }
    static var searchRegex: String { s(.searchRegex) }
    static var searchWord: String { s(.searchWord) }
    static var searchClear: String { s(.searchClear) }
    static var searchRunning: String { s(.searchRunning) }
    static var searchNothing: String { s(.searchNothing) }
    static func searchFailed(_ error: String) -> String { f(.searchFailed, error) }
    static func searchTruncated(_ n: Int) -> String { f(.searchTruncated, Int32(clamping: n)) }
    static func searchFileTruncated(_ n: Int) -> String { f(.searchFileTruncated, Int32(clamping: n)) }
    /// «12 совпадений в 3 файлах».
    /// Lines over 1 MiB the search dropped (minified files).
    static func searchSkipped(_ n: Int) -> String { count(n, .searchSkippedOne, .searchSkippedFew, .searchSkippedMany) }
    static func searchSummary(matches: Int, files: Int) -> String {
        count(matches, .searchMatchOne, .searchMatchFew, .searchMatchMany) + " " + count(files, .searchInFilesOne, .searchInFilesFew, .searchInFilesMany)
    }

    // «Сессии» (⌘Y)
    static var sessionsTitle: String { s(.sessionsTitle) }
    static var sessionsYesterday: String { s(.sessionsYesterday) }
    static var sessionsSearch: String { s(.sessionsSearch) }
    static var sessionsAll: String { s(.sessionsAll) }
    static var sessionsMore: String { s(.sessionsMore) }
    static var sessionsGo: String { s(.sessionsGo) }
    static var sessionsMarkerOpen: String { s(.sessionsMarkerOpen) }
    static var sessionsMarkerArchived: String { s(.sessionsMarkerArchived) }
    static var sessionsMarkerHistory: String { s(.sessionsMarkerHistory) }
    static var sessionsChipOpen: String { s(.sessionsChipOpen) }
    static var sessionsChipArchived: String { s(.sessionsChipArchived) }
    static var sessionsChipHistory: String { s(.sessionsChipHistory) }
    static var sessionsReset: String { s(.sessionsReset) }
    /// «Проект: shop».
    static func sessionsProjectChip(_ name: String) -> String { f(.sessionsProjectChip, name) }
    static var sessionsProjectChipHelp: String { s(.sessionsProjectChipHelp) }
    static var sessionsResetFilters: String { s(.sessionsResetFilters) }
    static func sessionsShowMore(_ n: Int) -> String { f(.sessionsShowMore, Int32(clamping: n)) }
    static func sessionsMessages(_ n: Int) -> String { f(.sessionsMessages, Int32(clamping: n)) }
    static var sessionsNoMatch: String { s(.sessionsNoMatch) }
    /// «По запросу «stripe» ничего нет».
    static func sessionsNoMatchQuery(_ query: String) -> String { f(.sessionsNoMatchQuery, query) }
    static var sessionsEmpty: String { s(.sessionsEmpty) }
    static var sessionsLoading: String { s(.sessionsLoading) }
    static func sessionsReadingHost(_ host: String) -> String { f(.sessionsReadingHost, host) }
    /// «devbox не ответил за 20 с».
    static func sessionsHostTimedOut(_ host: String, _ seconds: Int) -> String { f(.sessionsHostTimedOut, host, Int32(clamping: seconds)) }
    static func sessionsHostFailed(_ host: String) -> String { f(.sessionsHostFailed, host) }
    static func sessionsOffline(_ host: String) -> String { f(.sessionsOffline, host) }
    static var sessionsOfflineHint: String { s(.sessionsOfflineHint) }
    static var sessionsConnect: String { s(.sessionsConnect) }
    /// «Не удалось загрузить разговоры: …» (this Mac).
    static func sessionsLoadFailedLocal(_ message: String) -> String { f(.sessionsLoadFailedLocal, message) }
    static var sessionsTimedOut: String { s(.sessionsTimedOut) }
    static var sessionsContinue: String { s(.sessionsContinue) }
    static func sessionsContinueIn(_ session: String) -> String { f(.sessionsContinueIn, session) }
    static var sessionsContinueNew: String { s(.sessionsContinueNew) }
    static var sessionsRestoreHelp: String { s(.sessionsRestoreHelp) }
    static func sessionsHelpSession(_ name: String) -> String { f(.sessionsHelpSession, name) }
    /// «Сессия deploy-logs: 2 вкладки».
    static func sessionsArchivedHelp(_ name: String, _ tabs: String) -> String { f(.sessionsArchivedHelp, name, tabs) }
    static func sessionsArchivedSince(_ date: String) -> String { f(.sessionsArchivedSince, date) }
    static var projectSessions: String { s(.projectSessions) }
    static var sessionsUnknownError: String { s(.sessionsUnknownError) }
    /// «Архив · 3» under an empty project (#125).
    static func projectArchive(_ count: Int) -> String { f(.projectArchive, count) }
    static var sessionsUntitled: String { s(.sessionsUntitled) }
    static func sessionsTabs(_ n: Int) -> String { count(n, .sessionsTabOne, .sessionsTabFew, .sessionsTabMany) }


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
    static var conversationNotLinked: String { s(.conversationNotLinked) }
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
    static var escCancel: String { s(.escCancel) }
    static var cancel: String { s(.cancel) }
    static var create: String { s(.create) }
    static var branchRequired: String { s(.branchRequired) }
    static var branchInvalid: String { s(.branchInvalid) }
    static func branchExists(_ name: String) -> String { f(.branchExists, name) }
    // Branch switcher (#114): «Есть незакоммиченные изменения (3 файла).»
    static func branchDirty(_ files: String) -> String { f(.branchDirty, files) }
    static var branchDirtyHint: String { s(.branchDirtyHint) }
    static var branchDirtyNewHint: String { s(.branchDirtyNewHint) }
    static func branchCheckedOutInChat(_ branch: String, _ chat: String) -> String { f(.branchCheckedOutInChat, branch, chat) }
    static func branchCheckedOutAt(_ branch: String, _ path: String) -> String { f(.branchCheckedOutAt, branch, path) }
    static func branchIgnoredOverwrite(_ files: String) -> String { f(.branchIgnoredOverwrite, files) }
    /// `op` is git's own word: merge, rebase, am, cherry-pick, revert, bisect.
    static func branchOperationInProgress(_ op: String) -> String { f(.branchOperationInProgress, op) }
    static var fetchFailed: String { s(.fetchFailed) }
    static var createWithoutFetch: String { s(.createWithoutFetch) }
    static var fetchCancelled: String { s(.fetchCancelled) }
    static var noCommits: String { s(.noCommits) }
    static var worktreeLabel: String { s(.worktreeLabel) }
    static var newBranch: String { s(.newBranch) }
    static var whereToWork: String { s(.whereToWork) }
    static var whereFolder: String { s(.whereFolder) }
    /// «Ветка» / «Коммит» before the folder's mono HEAD: «Ветка `main`. Изменения увидят все чаты проекта.»
    static var whereFolderBranch: String { s(.whereFolderBranch) }
    static var whereFolderCommit: String { s(.whereFolderCommit) }
    static var whereFolderShared: String { s(.whereFolderShared) }
    static var whereCopy: String { s(.whereCopy) }
    static var whereCopyHint: String { s(.whereCopyHint) }
    static var copyNeedsCommit: String { s(.copyNeedsCommit) }
    static var branchFrom: String { s(.branchFrom) }
    static func taskFor(_ agent: String) -> String { f(.taskFor, agent) }
    static var taskLater: String { s(.taskLater) }
    static func chatNumbered(_ n: Int) -> String { f(.chatNumbered, n) }
    static var createHelp: String { s(.createHelp) }
    static var refreshHelp: String { s(.refreshHelp) }
    static var searchBranches: String { s(.searchBranches) }
    static var branchesRemote: String { s(.branchesRemote) }
    static var branchesLocal: String { s(.branchesLocal) }
    static var branchDefault: String { s(.branchDefault) }
    static var branchTask: String { s(.branchTask) }
    static var switcherSearch: String { s(.switcherSearch) }
    static var switcherLocal: String { s(.switcherLocal) }
    static var switcherRemote: String { s(.switcherRemote) }
    static var branchCurrent: String { s(.branchCurrent) }
    static func branchInChatNote(_ chat: String) -> String { f(.branchInChatNote, chat) }
    static var branchInFolderNote: String { s(.branchInFolderNote) }
    static func branchNewFrom(_ head: String) -> String { f(.branchNewFrom, head) }
    static var branchCreate: String { s(.branchCreate) }
    static func branchCreateNamed(_ name: String) -> String { f(.branchCreateNamed, name) }
    static var branchNamePrompt: String { s(.branchNamePrompt) }
    static func branchFromCurrent(_ head: String) -> String { f(.branchFromCurrent, head) }
    static func branchSwitching(_ name: String) -> String { f(.branchSwitching, name) }
    static func branchCreating(_ name: String) -> String { f(.branchCreating, name) }
    static var branchesLoading: String { s(.branchesLoading) }
    static var branchSwitchHint: String { s(.branchSwitchHint) }
    static func branchDirtyRepo(_ files: String) -> String { f(.branchDirtyRepo, files) }
    static func branchSwitched(_ name: String) -> String { f(.branchSwitched, name) }
    static func branchCreated(_ name: String) -> String { f(.branchCreated, name) }
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
    static var terminalTab: String { s(.terminalTab) }
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
    static var paneNew: String { s(.paneNew) }
    static var paneEditorCap: String { s(.paneEditorCap) }
    static var continueTitle: String { s(.continueTitle) }
    static var closePane: String { s(.closePane) }
    static var detachPane: String { s(.detachPane) }
    static var dropRight: String { s(.dropRight) }
    static var dropLeft: String { s(.dropLeft) }
    static var dropUp: String { s(.dropUp) }
    static var dropDown: String { s(.dropDown) }
    static var paneAgentWorking: String { s(.paneAgentWorking) }
    static var paneAgentWorkingInfo: String { s(.paneAgentWorkingInfo) }
    static var tabAgentWorkingInfo: String { s(.tabAgentWorkingInfo) }
    static var editor: String { s(.editor) }
    static var externalEditor: String { s(.externalEditor) }
    static var externalEditorPlaceholder: String { s(.externalEditorPlaceholder) }
    static var appearance: String { s(.appearance) }
    static var themeTitle: String { s(.themeTitle) }
    static var themeGraphite: String { s(.themeGraphite) }
    static var settingsGeneral: String { s(.settingsGeneral) }
    static var settingsNotifications: String { s(.settingsNotifications) }
    static var settingsIntegrations: String { s(.settingsIntegrations) }
    static var settingsAdvanced: String { s(.settingsAdvanced) }
    static var configFile: String { s(.configFile) }
    static var showInFinder: String { s(.showInFinder) }
    static var pillInstalled: String { s(.pillInstalled) }
    static var pillMissing: String { s(.pillMissing) }
    static var pillOutdated: String { s(.pillOutdated) }
    static var pillUnavailable: String { s(.pillUnavailable) }
    static var pillChecking: String { s(.pillChecking) }
    static var pillError: String { s(.pillError) }
    static var sectionProjectTitle: String { s(.sectionProjectTitle) }
    static var sectionToolsTitle: String { s(.sectionToolsTitle) }
    static func saveFailed(_ error: String) -> String { f(.saveFailed, error) }
    static var notificationsTitle: String { s(.notificationsTitle) }
    static var limitNotificationsTitle: String { s(.limitNotificationsTitle) }
    static var toggleOn: String { s(.toggleOn) }
    static var toggleOff: String { s(.toggleOff) }
    static func agentPermission(_ agent: String) -> String { f(.agentPermission, agent) }
    static func agentQuestion(_ agent: String) -> String { f(.agentQuestion, agent) }
    static func agentDone(_ agent: String) -> String { f(.agentDone, agent) }
    static func agentFailed(_ agent: String) -> String { f(.agentFailed, agent) }
    static func agentLimit(_ agent: String) -> String { f(.agentLimit, agent) }
    static var notifyPermissionTitle: String { s(.notifyPermissionTitle) }
    static var notifyQuestionTitle: String { s(.notifyQuestionTitle) }
    static var notifyDoneTitle: String { s(.notifyDoneTitle) }
    static var notifyFailedTitle: String { s(.notifyFailedTitle) }
    static var soundTitle: String { s(.soundTitle) }
    static var soundNone: String { s(.soundNone) }
    static var soundDefault: String { s(.soundDefault) }
    static var allowFromNotificationTitle: String { s(.allowFromNotificationTitle) }
    static var allowFromNotificationHelp: String { s(.allowFromNotificationHelp) }
    static var notifyWhenActiveTitle: String { s(.notifyWhenActiveTitle) }
    static var notifyWhenActiveHelp: String { s(.notifyWhenActiveHelp) }
    static var sshTerminalBellTitle: String { s(.sshTerminalBellTitle) }
    static var sshTerminalBellHelp: String { s(.sshTerminalBellHelp) }
    static var notificationPermissionTitle: String { s(.notificationPermissionTitle) }
    static var notificationsAllowedInSystem: String { s(.notificationsAllowedInSystem) }
    static var notificationsNotAsked: String { s(.notificationsNotAsked) }
    static var notificationsDeniedInSystem: String { s(.notificationsDeniedInSystem) }
    static var openSystemSettings: String { s(.openSystemSettings) }
    static var urgentNotice: String { s(.urgentNotice) }
    static var muteSession: String { s(.muteSession) }
    static var unmuteSession: String { s(.unmuteSession) }
    static var projectNotificationsTitle: String { s(.projectNotificationsTitle) }
    static var mutedSessionHelp: String { s(.mutedSessionHelp) }
    /// The project menu item: the current mode, a click moves to the next.
    static func projectNotificationsItem(_ mode: ProjectNotifications) -> String {
        switch mode {
        case .all: s(.projectNotificationsAll)
        case .urgent: s(.projectNotificationsUrgent)
        case .off: s(.projectNotificationsOff)
        }
    }
    static func notifySegment(_ mode: ProjectNotifications) -> String {
        switch mode {
        case .all: s(.notifySegmentAll)
        case .urgent: s(.notifySegmentUrgent)
        case .off: s(.notifySegmentOff)
        }
    }
    static var noticeOpen: String { s(.noticeOpen) }
    static var noticeAllow: String { s(.noticeAllow) }
    static var noticeReply: String { s(.noticeReply) }
    static var noticeOpenLimits: String { s(.noticeOpenLimits) }
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
    static var statuslineTitle: String { s(.statuslineTitle) }
    static var statuslineShow: String { s(.statuslineShow) }
    static var statuslineHangar: String { s(.statuslineHangar) }
    static var statuslineUser: String { s(.statuslineUser) }
    static var statuslineHangarHelp: String { s(.statuslineHangarHelp) }
    static func statuslineUserHelp(_ command: String) -> String { f(.statuslineUserHelp, command) }
    static var statuslineNoOwnHelp: String { s(.statuslineNoOwnHelp) }
    static var statuslinePreview: String { s(.statuslinePreview) }
    static var statuslineUserPreview: String { s(.statuslineUserPreview) }
    static var statuslineParts: String { s(.statuslineParts) }
    static var statuslineNeedsIntegration: String { s(.statuslineNeedsIntegration) }
    static var statuslineChipHelp: String { s(.statuslineChipHelp) }
    static var statuslineMoveLeft: String { s(.statuslineMoveLeft) }
    static var statuslineMoveRight: String { s(.statuslineMoveRight) }
    static var statuslineSegModel: String { s(.statuslineSegModel) }
    static var statuslineSegContext: String { s(.statuslineSegContext) }
    static var statuslineSegFiveHour: String { s(.statuslineSegFiveHour) }
    static var statuslineSegWeek: String { s(.statuslineSegWeek) }
    static var statuslineSegBranch: String { s(.statuslineSegBranch) }
    static var statuslineSegEffort: String { s(.statuslineSegEffort) }
    static var fileReadOnly: String { s(.fileReadOnly) }
    static var statuslineProjects: String { s(.statuslineProjects) }
    static var statuslineProjectsHelp: String { s(.statuslineProjectsHelp) }
    static var statuslineOverridden: String { s(.statuslineOverridden) }
    static var statuslineNotIgnored: String { s(.statuslineNotIgnored) }
    static func statuslineFailed(_ why: String) -> String { f(.statuslineFailed, why) }
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
    static var limitSessionShort: String { s(.limitSessionShort) }
    static var limitWeekShort: String { s(.limitWeekShort) }
    static var limitNoData: String { s(.limitNoData) }
    static var limitWeekAll: String { s(.limitWeekAll) }
    static var limitWeek: String { s(.limitWeek) }
    static func limitWeekModel(_ model: String) -> String { f(.limitWeekModel, model) }
    static func resetIn(_ duration: String, _ time: String) -> String { f(.resetIn, duration, time) }
    static func durationMin(_ m: Int) -> String { f(.durationMin, m) }
    static var durationUnderMin: String { s(.durationUnderMin) }
    static func durationHour(_ h: Int) -> String { f(.durationHour, h) }
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
    static var linkNotFound: String { s(.linkNotFound) }
    static var attentionOnly: String { s(.attentionOnly) }
    static var nobodyWaiting: String { s(.nobodyWaiting) }
    static var inbox: String { s(.inbox) }
    static var inboxRecentDone: String { s(.inboxRecentDone) }
    static var inboxDismiss: String { s(.inboxDismiss) }
    static var inboxClear: String { s(.inboxClear) }
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
    static func worktreeRootInsideProject(_ sibling: String) -> String { f(.worktreeRootInsideProject, sibling) }
    static var worktreesInsideNotice: String { s(.worktreesInsideNotice) }
    static var keepWorktreesBeside: String { s(.keepWorktreesBeside) }
    static func keepWorktreesBesideHelp(_ folder: String) -> String { f(.keepWorktreesBesideHelp, folder) }
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
    static var thisMac: String { s(.thisMac) }
    static var notifySectionEvents: String { s(.notifySectionEvents) }
    static var notifySectionSystem: String { s(.notifySectionSystem) }
    // Session rows (redesign v1): «ждёт · 1 агент», «работает · 2 субагента», «нет агентов · 1 вкладка»
    private static func count(_ n: Int, _ one: Key, _ few: Key, _ many: Key) -> String {
        // Russian has three forms by the last digits; English only «1» vs the rest (21 results, not 21 result).
        let form = resolve(language) == .ru ? pluralForm(n) : abs(n) == 1 ? .one : .many
        let key: Key = switch form {
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
    static var segmentChangesTitle: String { s(.segmentChangesTitle) }
    static var changesWholeBranch: String { s(.changesWholeBranch) }
    static func changesHintToBase(_ branch: String) -> String { f(.changesHintToBase, branch) }
    static var changesHintUncommitted: String { s(.changesHintUncommitted) }
    static var changesHintToUncommitted: String { s(.changesHintToUncommitted) }
    static func baseMissing(_ branch: String) -> String { f(.baseMissing, branch) }
    static var baseMissingUnknown: String { s(.baseMissingUnknown) }
    static var noChanges: String { s(.noChanges) }
    static func statusTruncated(_ n: Int) -> String { f(.statusTruncated, Int32(clamping: n)) }
    static func filesTruncated(_ n: Int) -> String { f(.filesTruncated, Int32(clamping: n)) }
    static func gitFailed(_ message: String) -> String { f(.gitFailed, message) }
    static var inspectorHostShell: String { s(.inspectorHostShell) }

    // Git tab (redesign v1 §4)
    static var segmentGit: String { s(.segmentGit) }
    static var showGit: String { s(.showGit) }
    static var gitBranch: String { s(.gitBranch) }
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
    static var opensMenu: String { s(.opensMenu) }
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
    static func lspLoading(_ server: String) -> String { f(.lspLoading, server) }
    static func lspStopped(_ server: String) -> String { f(.lspStopped, server) }
    static func lspMissing(_ language: String) -> String { f(.lspMissing, language) }
    static func lspMissingTip(_ servers: String) -> String { f(.lspMissingTip, servers) }
    static func lspTooltip(_ executable: String) -> String { f(.lspTooltip, executable) }
    static var lspSection: String { s(.lspSection) }
    static func lspInstalledFrom(_ a: String) -> String { f(.lspInstalledFrom, a) }
    static var lspNotInstalled: String { s(.lspNotInstalled) }
    static var lspFromProject: String { s(.lspFromProject) }
    static var lspSourceProject: String { s(.lspSourceProject) }
    static var lspTsDetail: String { s(.lspTsDetail) }
    static var lspNeedsXcode: String { s(.lspNeedsXcode) }
    static var lspXcodeTip: String { s(.lspXcodeTip) }
    static var lspNeedsNode: String { s(.lspNeedsNode) }
    static var lspNeedsGo: String { s(.lspNeedsGo) }
    static var lspDownload: String { s(.lspDownload) }
    static func lspDownloadTip(_ a: String, _ b: String) -> String { f(.lspDownloadTip, a, b) }
    static var lspRemove: String { s(.lspRemove) }
    static var lspRetry: String { s(.lspRetry) }
    static func lspDownloading(_ n: Int) -> String { f(.lspDownloading, Int32(clamping: n)) }
    static var lspInstalling: String { s(.lspInstalling) }
    static func lspToolFailed(_ n: Int) -> String { f(.lspToolFailed, Int32(clamping: n)) }
    static var lspNoAsset: String { s(.lspNoAsset) }
    static func lspDownloadFailed(_ a: String) -> String { f(.lspDownloadFailed, a) }
    static var lspNotOwned: String { s(.lspNotOwned) }
    static var lspNoExecutable: String { s(.lspNoExecutable) }
    static var lspNotExecutable: String { s(.lspNotExecutable) }
    static var downloadTooLarge: String { s(.downloadTooLarge) }
    static func diffTooLarge(_ n: Int) -> String { f(.diffTooLarge, Int32(clamping: n)) }
    static func diffModeChange(_ old: String, _ new: String) -> String { f(.diffModeChange, old, new) }
    static func diffRenamedFrom(_ path: String) -> String { f(.diffRenamedFrom, path) }
    static var diffNotChanged: String { s(.diffNotChanged) }
    static var diffNotAFile: String { s(.diffNotAFile) }
    static var diffTabHelp: String { s(.diffTabHelp) }
    static var diffNoChanges: String { s(.diffNoChanges) }
    static func diffChangeCounter(_ index: Int, _ count: Int) -> String { f(.diffChangeCounter, index, count) }
    static var diffPrevChange: String { s(.diffPrevChange) }
    static var diffNextChange: String { s(.diffNextChange) }

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
        case .nextAttention: s(.cmdNextAttention)
        case .nextWorking: s(.cmdNextWorking)
        case .sessions: sessionsTitle
        case .findInFiles: s(.cmdFindInFiles)
        case .tab(let n): "\(n)"
        case .focusSplit: ""
        }
    }
}
