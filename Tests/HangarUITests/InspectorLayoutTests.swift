import Foundation
import Git
import Testing
@testable import HangarUI

@MainActor @Suite struct InspectorLayoutTests {
    /// Up to half the window (HD-162), never under the minimum.
    @Test func widthClamped() {
        #expect(clampInspectorWidth(1000, window: 1200) == 600)
        #expect(clampInspectorWidth(1000, window: 1441) == 720)
        #expect(clampInspectorWidth(100, window: 1200) == 280)
        #expect(clampInspectorWidth(320, window: 1200) == 320)
        #expect(clampInspectorWidth(400, window: 640) == 320)
        #expect(clampInspectorWidth(400, window: 400) == 280)
    }

    private func layout(_ window: CGFloat, inspector: Bool = true, rail: Bool = false, chatOnly: Bool = false,
                        keepInspector: Bool = false, keepSidebar: Bool = false) -> PanelLayout {
        panelLayout(window: window, sidebar: 256, inspector: 320, wantsInspector: inspector, wantsRail: rail, chatOnly: chatOnly,
                    keepInspector: keepInspector, keepSidebar: keepSidebar)
    }

    /// Chat ≥ 420: the inspector goes first, then the sidebar shrinks to its rail; widening brings them back (HD-162).
    @Test func adaptivePanels() {
        // 256 + 1 + 420 + 1 + 320 = 998
        #expect(layout(1440) == PanelLayout(inspector: true, sidebarRail: false))
        #expect(layout(998) == PanelLayout(inspector: true, sidebarRail: false))
        #expect(layout(997) == PanelLayout(inspector: false, sidebarRail: false))
        // 256 + 1 + 420 = 677
        #expect(layout(677) == PanelLayout(inspector: false, sidebarRail: false))
        #expect(layout(676) == PanelLayout(inspector: false, sidebarRail: true))
        #expect(layout(640) == PanelLayout(inspector: false, sidebarRail: true))
        // What the user hid stays hidden; a rail stays a rail at any width.
        #expect(layout(1440, inspector: false) == PanelLayout(inspector: false, sidebarRail: false))
        #expect(layout(1440, rail: true) == PanelLayout(inspector: true, sidebarRail: true))
        // With the sidebar on its rail the inspector fits sooner: 44 + 1 + 420 + 1 + 320 = 786.
        #expect(layout(786, rail: true) == PanelLayout(inspector: true, sidebarRail: true))
        #expect(layout(785, rail: true) == PanelLayout(inspector: false, sidebarRail: true))
    }

    @Test func chatOnlyAndKeptPanels() {
        #expect(layout(1440, chatOnly: true) == PanelLayout(inspector: false, sidebarRail: true))
        // Shown by the user in a narrow window: the inspector stays, the sidebar gives way.
        #expect(layout(760, keepInspector: true) == PanelLayout(inspector: true, sidebarRail: true))
        #expect(layout(640, keepSidebar: true) == PanelLayout(inspector: false, sidebarRail: false))
    }

    @Test func diffNarrowBreakpoint() {
        #expect(diffIsNarrow(width: 899))
        #expect(!diffIsNarrow(width: 900))
        #expect(!diffIsNarrow(width: 0))  // not laid out yet
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
