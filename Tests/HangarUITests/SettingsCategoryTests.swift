import AppKit
import Integration
import Testing
import Workspace
@testable import HangarUI

/// Settings window (System Settings style): the category list and the one-line label column.
@MainActor @Suite struct SettingsCategoryTests {
    @Test func categoriesInOrderWithOwnIcons() {
        #expect(SettingsCategory.allCases == [.general, .appearance, .editor, .notifications, .integrations, .advanced])
        #expect(Set(SettingsCategory.allCases.map(\.icon)).count == SettingsCategory.allCases.count)
    }

    /// Every title and row label exists in both languages (not the key name).
    @Test(arguments: [Language.ru, .en]) func titlesAndLabelsAreTranslated(_ lang: Language) {
        for category in SettingsCategory.allCases {
            let title = L10n.lookup(category.titleKey, lang, in: L10n.resources)
            #expect(title != category.titleKey.rawValue && !title.isEmpty)
            #expect(!category.labelKeys.isEmpty, "\(category)")
            for key in category.labelKeys { #expect(L10n.lookup(key, lang, in: L10n.resources) != key.rawValue) }
        }
    }

    /// The label column fits the longest label of the language on one line, and leaves the value its room.
    @Test(arguments: [Language.ru, .en]) func labelColumnFitsTheLongestLabel(_ lang: Language) {
        let width = settingsLabelWidth(lang)
        let labels = SettingsCategory.allCases.flatMap(\.labelKeys).map { L10n.lookup($0, lang, in: L10n.resources) }
        for label in labels { #expect(settingsLabelTextWidth(label) <= width, "\(label)") }
        #expect(width <= Theme.settingsLabelMax)
        // ru «Уведомления о лимитах» is the longest; the column is not wider than it needs.
        #expect(width - (labels.map(settingsLabelTextWidth).max() ?? 0) < 2)
    }

    /// Integration status pill: green when installed, amber for a to-do, red only for errors.
    @Test func integrationPills() {
        #expect(integrationPill(.installed).color == Theme.ui.done)
        #expect(integrationPill(.installedStatuslineByUser).color == Theme.ui.done)
        #expect(integrationPill(.notInstalled).color == Theme.ui.waiting)
        #expect(integrationPill(.outdated).color == Theme.ui.waiting)
        #expect(integrationPill(.notInstalled).text == L10n.pillMissing)
    }
}
