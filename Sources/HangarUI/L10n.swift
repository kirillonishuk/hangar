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
        case folderMissingPath, keepAwake, more, settings, settingsHelp, settingsEllipsis
        case collapse, collapseSidebarHelp, expandSidebarHelp, inspectorHelp, newTabHelp, closeTabHelp
        case taskNamePlaceholder, firstMessagePlaceholder, escCancel, cancel, create, configNotApplied
        case usingDefaults, launchFailed, terminalCreateFailed, exited, exitedWithCode, relaunchHint
        case emptyNoTask, emptyNoTabs, ghosttyFailed, retry, quit, menuHide
        case menuQuit, menuEdit, undo, redo, cut, copy
        case paste, selectAll, languageTitle, languageSystem, languageRu, languageEn
        case defaultAgent, editor, externalEditor, externalEditorPlaceholder, terminalBackground, backgroundTheme
        case afterRestart, saveFailed
        case revealInFinder, copyPath, openIn, openFailed, deletePermanently, deleteTaskConfirm, deleteTaskInfo, delete
        case alsoDeleteWorktree, worktreeDirty, worktreeDirtyInfo, deleteAnyway, worktreeRemoveFailed, branchKept
        case projectSettingsEllipsis, projectSettings, removeFromHangar, removeProjectConfirm, removeProjectInfo, remove, splitRight, splitDown
        case drawerTitle, drawerToggle, drawerHelp
        case closeTab, projectName, projectPath, chooseEllipsis, defaultBranch, worktreeFolder, creatingWorktreeWait, worktreeRootInsideProject, pathMustBeAbsolute, branchAuto, save
        case ok, exitStatus, stateCorrupt, stateUnreadable
        case clipboardRead, clipboardPasteUnsafe, allow
        case branchRequired, branchInvalid, branchExists, fetchFailed, createWithoutFetch, fetchCancelled, noCommits
        case worktreeLabel, worktreeOnHint, worktreeOffHint, fromBranch, newBranch, fromName, currentBranch, refreshHelp
        case searchBranches, branchesRemote, branchesLocal, branchDefault, branchTask
        case updatedAgo, justNow, minutesAgo, hoursAgo, daysAgo
    }

    // Sidebar
    static var sectionPinned: String { s(.sectionPinned) }
    static var sectionProjects: String { s(.sectionProjects) }
    static var sectionArchived: String { s(.sectionArchived) }
    static var sectionSSHHosts: String { s(.sectionSSHHosts) }
    static var newTask: String { s(.newTask) }
    static var newTaskHelp: String { s(.newTaskHelp) }
    static func newTaskIn(_ project: String) -> String { f(.newTaskIn, project) }
    static var addProject: String { s(.addProject) }
    static var addProjectEllipsis: String { s(.addProjectEllipsis) }
    static var restore: String { s(.restore) }
    static var rename: String { s(.rename) }
    static var pin: String { s(.pin) }
    static var unpin: String { s(.unpin) }
    static var archive: String { s(.archive) }
    static var folderMissing: String { s(.folderMissing) }
    static func folderMissing(_ path: String) -> String { f(.folderMissingPath, path) }
    static var keepAwake: String { s(.keepAwake) }
    static var more: String { s(.more) }
    static var settings: String { s(.settings) }
    static var settingsHelp: String { s(.settingsHelp) }
    static var settingsEllipsis: String { s(.settingsEllipsis) }
    static var collapse: String { s(.collapse) }
    static var collapseSidebarHelp: String { s(.collapseSidebarHelp) }
    static var expandSidebarHelp: String { s(.expandSidebarHelp) }

    // Title bar, tabs, new-task sheet
    static var inspectorHelp: String { s(.inspectorHelp) }
    static var newTabHelp: String { s(.newTabHelp) }
    static var closeTabHelp: String { s(.closeTabHelp) }
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

    // Actions (context menus), project settings
    static var revealInFinder: String { s(.revealInFinder) }
    static var copyPath: String { s(.copyPath) }
    static func openIn(_ arg: String) -> String { f(.openIn, arg) }
    static func openFailed(_ arg: String) -> String { f(.openFailed, arg) }
    static var deletePermanently: String { s(.deletePermanently) }
    static func deleteTaskConfirm(_ arg: String) -> String { f(.deleteTaskConfirm, arg) }
    static var deleteTaskInfo: String { s(.deleteTaskInfo) }
    static var alsoDeleteWorktree: String { s(.alsoDeleteWorktree) }
    static var worktreeDirty: String { s(.worktreeDirty) }
    static var worktreeDirtyInfo: String { s(.worktreeDirtyInfo) }
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
    static var pathMustBeAbsolute: String { s(.pathMustBeAbsolute) }
    static func branchAuto(_ value: String) -> String { f(.branchAuto, value) }
    static var save: String { s(.save) }
    public static var ok: String { s(.ok) }
    static func exitStatus(_ code: Int32) -> String { f(.exitStatus, code) }
}
