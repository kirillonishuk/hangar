import Foundation
import GhosttyBridge
import Testing
@testable import HangarUI
import Workspace

@MainActor @Suite struct L10nTests {
    @Test func allKeysHaveRuAndEn() throws {
        let keys = Set(L10n.Key.allCases.map(\.rawValue))
        for lang in [Language.ru, .en] {
            let table = try #require(L10n.table(lang), "no table for \(lang)")
            #expect(Set(table.keys) == keys, "\(lang): extra \(Set(table.keys).subtracting(keys)), missing \(keys.subtracting(table.keys))")
            for (key, value) in table { #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(lang): empty \(key)") }
        }
    }

    /// The UI says «сессия» / "session", never «задача» / "task" (#NN-sessions); code keeps `Task` identifiers.
    @Test func sessionsNotTasks() throws {
        for (lang, banned) in [(Language.ru, "задач"), (.en, "task")] {
            let table = try #require(L10n.table(lang))
            for (key, value) in table { #expect(!value.lowercased().contains(banned), "\(lang): \(key) = \(value)") }
        }
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.newTask == "Новая сессия")
        #expect(L10n.taskArchived == "Сессия в архиве")
        #expect(L10n.deleteTaskConfirm("A") == "Удалить сессию «A» навсегда?")
        #expect(L10n.newTaskIn("web") == "Новая сессия в web")
        L10n.language = .en
        #expect(L10n.newTask == "New Session")
        #expect(L10n.taskArchived == "Session archived")
    }

    @Test func clipboardPromptIsLocalized() {
        defer { L10n.language = .system }
        L10n.language = .ru
        let ru = L10n.clipboardPromptText()
        #expect(ru.allow == "Разрешить" && ru.cancel == "Отмена")
        #expect(ru.pasteUnsafe == "Вставить текст, который может выполнить команды?")
        #expect(ru.readClipboard == "Программа хочет прочитать буфер обмена")
        L10n.language = .en
        #expect(L10n.clipboardPromptText().allow == "Allow")
        #expect(L10n.clipboardPromptText().readClipboard == "A program wants to read the clipboard")
    }

    @Test func integrationStrings() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.settingsInvalidJSON(3) == "settings.json: ошибка JSON в строке 3 — исправьте файл вручную")
        #expect(L10n.fileChanged == "Файл изменился — проверьте изменения ещё раз")
        #expect(L10n.codexConfigUnsupported == "config.toml: notify в неподдерживаемом виде — правьте вручную")
        #expect(L10n.integrationConfirmTitle("~/.claude/settings.json") == "Изменить ~/.claude/settings.json?")
        #expect(L10n.backupWillBeCreated("a.bak") == "Будет создана копия: a.bak")
        #expect(L10n.hooksMissing == "Hooks не установлены — статусы только по bell и выходу процесса")
        #expect(L10n.codexNotFound == "Codex не найден")
        #expect(L10n.linesUnchanged(12) == "… 12 строк без изменений")
        L10n.language = .en
        #expect(L10n.settingsInvalidJSON(3) == "settings.json: JSON error on line 3 — fix the file manually")
        #expect(L10n.fileChanged == "The file changed — review the changes again")
        #expect(L10n.codexConfigUnsupported == "config.toml: unsupported notify — edit it manually")
        #expect(L10n.integrationConfirmTitle("x") == "Change x?")
        #expect(L10n.backupWillBeCreated("a.bak") == "A backup will be created: a.bak")
    }

    @Test func pluralizedExitCode() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.exitedWithCode(3) == "процесс завершился с кодом 3")
        #expect(L10n.sectionPinned == "ЗАКРЕПЛЁННЫЕ")
        L10n.language = .en
        #expect(L10n.exitedWithCode(3) == "process exited with code 3")
        #expect(L10n.sectionPinned == "PINNED")
    }

    /// One tooltip for the ☕ in the Settings row and in the rail.
    @Test func keepAwakeHelpFollowsState() {
        defer { L10n.language = .system }
        L10n.language = .en
        #expect(L10n.keepAwakeHelp(enabled: false, held: true, working: 2) == "Keep awake: off")
        #expect(L10n.keepAwakeHelp(enabled: true, held: false, working: 0) == "Keep awake: on — the Mac won't sleep while agents work")
        #expect(L10n.keepAwakeHelp(enabled: true, held: true, working: 2) == "Keep awake: on — the Mac stays awake, agents working: 2")
        #expect(L10n.keepAwakeHelp(enabled: true, held: true, working: 0) == "Keep awake: on — the Mac stays awake for up to 2 more min")
        L10n.language = .ru
        #expect(L10n.keepAwakeHelp(enabled: false, held: false, working: 0) == "Не засыпать: выключено")
        #expect(L10n.keepAwakeHelp(enabled: true, held: false, working: 0) == "Не засыпать: включено — Mac не уснёт, пока агенты работают")
    }

    @Test func systemLanguageResolution() {
        #expect(L10n.resolve(.system, preferred: ["ru-RU", "en-US"]) == .ru)
        #expect(L10n.resolve(.system, preferred: ["de-DE", "ru-RU"]) == .en)
        #expect(L10n.resolve(.system, preferred: []) == .en)
        #expect(L10n.resolve(.ru, preferred: ["en"]) == .ru)
    }

    @Test func missingBundleReturnsKeys() {
        let bogus = L10n.findResources(in: [URL(fileURLWithPath: "/nonexistent/hangar")])
        #expect(bogus == nil)
        #expect(L10n.lookup(.sectionPinned, .ru, in: bogus) == "sectionPinned")
        #expect(L10n.lookup(.exitedWithCode, .en, in: bogus) == "exitedWithCode")
        // The real search finds the bundle without touching SwiftPM's fatalError-ing Bundle.module.
        #expect(L10n.lookup(.sectionPinned, .en, in: L10n.resources) == "PINNED")
    }
}
