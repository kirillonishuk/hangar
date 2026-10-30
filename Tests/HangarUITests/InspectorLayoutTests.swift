import Foundation
import Git
import Testing
@testable import HangarUI

@MainActor @Suite struct InspectorLayoutTests {
    @Test func widthClamped() {
        #expect(clampInspectorWidth(1000) == 420)
        #expect(clampInspectorWidth(100) == 300)
        #expect(clampInspectorWidth(340) == 340)
    }

    @Test func inspectorStrings() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.segmentChanges(3) == "Изменения 3")
        #expect(L10n.segmentChangesTitle == "Изменения")
        #expect(L10n.changesHintUncommitted == "Не в коммите")
        // The mode chips' tooltips: «Действие — клавиша».
        #expect(L10n.changesHintToBase("main") == "Сравнить с main — ⌥B")
        #expect(L10n.changesHintToUncommitted == "Только не в коммите — ⌥B")
        #expect(L10n.baseMissing("dev") == "Базовая ветка dev не найдена — показано то, что не в коммите")
        #expect(L10n.baseMissingUnknown == "Базовая ветка не найдена — показано то, что не в коммите")
        #expect(L10n.statusTruncated(50) == "Показаны первые 50 изменений")
        L10n.language = .en
        #expect(L10n.changesHintToUncommitted == "Not committed only — ⌥B")
        #expect(L10n.filesTruncated(200_000) == "Not all files shown (over 200,000)")
        #expect(L10n.gitFailed("boom") == "git: boom")
        #expect(L10n.baseMissingUnknown == "Base branch not found — showing what's not committed")
        #expect(L10n.filesTruncated(FileListing.limit) == "Not all files shown (over 200,000)")
    }
}
