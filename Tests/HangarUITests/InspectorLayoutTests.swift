import Foundation
import Git
import Testing
@testable import HangarUI

@MainActor @Suite struct InspectorLayoutTests {
    @Test func widthClamped() {
        #expect(clampInspectorWidth(1000) == 480)
        #expect(clampInspectorWidth(100) == 180)
        #expect(clampInspectorWidth(300) == 300)
    }

    @Test func inspectorStrings() {
        defer { L10n.language = .system }
        L10n.language = .ru
        #expect(L10n.segmentChanges(3) == "Changes 3")
        #expect(L10n.changesHintBase("main") == "Сравнение с базовой веткой main")
        #expect(L10n.baseMissing("dev") == "Базовая ветка dev не найдена — показано незакоммиченное")
        #expect(L10n.baseMissingUnknown == "Базовая ветка не найдена — показано незакоммиченное")
        #expect(L10n.statusTruncated(50) == "Показаны первые 50 изменений")
        L10n.language = .en
        #expect(L10n.changesHintToUncommitted == "⌥B — uncommitted only")
        #expect(L10n.filesTruncated(200_000) == "Not all files shown (over 200,000)")
        #expect(L10n.gitFailed("boom") == "git: boom")
        #expect(L10n.baseMissingUnknown == "Base branch not found — showing uncommitted")
        #expect(L10n.filesTruncated(FileListing.limit) == "Not all files shown (over 200,000)")
    }
}
