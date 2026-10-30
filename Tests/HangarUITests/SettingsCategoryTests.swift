import AppKit
import Integration
import Testing
import Workspace
@testable import HangarUI

/// Settings window: the category list.
@MainActor @Suite struct SettingsCategoryTests {
    @Test func categoriesInOrderWithOwnIcons() {
        #expect(SettingsCategory.allCases == [.general, .appearance, .notifications, .integrations, .advanced])
        #expect(Set(SettingsCategory.allCases.map(\.icon)).count == SettingsCategory.allCases.count)
    }

    /// Every title exists in both languages (not the key name).
    @Test(arguments: [Language.ru, .en]) func titlesAreTranslated(_ lang: Language) {
        for category in SettingsCategory.allCases {
            let title = L10n.lookup(category.titleKey, lang, in: L10n.resources)
            #expect(title != category.titleKey.rawValue && !title.isEmpty)
        }
    }
}
