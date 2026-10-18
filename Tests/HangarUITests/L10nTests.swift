import Foundation
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

    @Test func pluralizedExitCode() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.exitedWithCode(3) == "процесс завершился с кодом 3")
        #expect(L10n.sectionPinned == "ЗАКРЕПЛЁННЫЕ")
        L10n.language = .en
        #expect(L10n.exitedWithCode(3) == "process exited with code 3")
        #expect(L10n.sectionPinned == "PINNED")
    }

    @Test func systemLanguageResolution() {
        #expect(L10n.resolve(.system, preferred: ["ru-RU", "en-US"]) == .ru)
        #expect(L10n.resolve(.system, preferred: ["de-DE", "ru-RU"]) == .en)
        #expect(L10n.resolve(.system, preferred: []) == .en)
        #expect(L10n.resolve(.ru, preferred: ["en"]) == .ru)
    }
}
