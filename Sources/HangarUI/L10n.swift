import Foundation
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
        case newTaskIn, addProject, addProjectEllipsis, restore, renameEllipsis, rename
        case renameTask, renameProject, pin, unpin, archive, folderMissing
        case folderMissingPath, keepAwake, more, settings, settingsHelp, settingsEllipsis
        case collapse, collapseSidebarHelp, expandSidebarHelp, inspectorHelp, newTabHelp, closeTabHelp
        case taskNamePlaceholder, firstMessagePlaceholder, escCancel, cancel, create, configNotApplied
        case usingDefaults, launchFailed, terminalCreateFailed, exited, exitedWithCode, relaunchHint
        case emptyNoTask, emptyNoTabs, ghosttyFailed, retry, quit, menuHide
        case menuQuit, menuEdit, undo, redo, cut, copy
        case paste, selectAll, languageTitle, languageSystem, languageRu, languageEn
        case defaultAgent, editor, externalEditor, externalEditorPlaceholder, terminalBackground, backgroundTheme
        case afterRestart, saveFailed
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
    static var renameEllipsis: String { s(.renameEllipsis) }
    static var rename: String { s(.rename) }
    static var renameTask: String { s(.renameTask) }
    static var renameProject: String { s(.renameProject) }
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
}
