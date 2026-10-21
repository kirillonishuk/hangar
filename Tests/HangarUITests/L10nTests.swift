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

    @Test func keepAwakeAssertionPlurals() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.keepAwakeAssertion(0) == "Hangar: 0 агентов работают")
        #expect(L10n.keepAwakeAssertion(1) == "Hangar: 1 агент работает")
        #expect(L10n.keepAwakeAssertion(3) == "Hangar: 3 агента работают")
        for n in [5, 11, 12, 14, 20, 111] { #expect(L10n.keepAwakeAssertion(n) == "Hangar: \(n) агентов работают") }
        #expect(L10n.keepAwakeAssertion(21) == "Hangar: 21 агент работает")
        #expect(L10n.keepAwakeAssertion(101) == "Hangar: 101 агент работает")
        #expect(L10n.keepAwakeAssertion(22) == "Hangar: 22 агента работают")
        L10n.language = .en
        #expect(L10n.keepAwakeAssertion(1) == "Hangar: 1 agent working")
        #expect(L10n.keepAwakeAssertion(2) == "Hangar: 2 agents working")
        #expect(L10n.keepAwakeAssertion(21) == "Hangar: 21 agents working")
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
