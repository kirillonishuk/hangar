import Testing
@testable import HangarUI

/// The chat's name when «Название» is left empty (decision #116).
@MainActor @Suite struct ChatNameTests {
    @Test func typedNameWins() {
        #expect(chatName(name: "  fix-login  ", message: "Почини логин", existing: []) == "fix-login")
    }

    @Test func emptyNameTakesTheMessagesFirstLine() {
        #expect(chatName(name: " ", message: "\n  Почини   редирект после логина \nподробности", existing: []) == "Почини редирект после логина")
    }

    @Test func markdownMarkersAndInvisibleCharsAreDropped() {
        #expect(chatName(name: "", message: "## Почини логин", existing: []) == "Почини логин")
        #expect(chatName(name: "", message: "> - * Почини логин", existing: []) == "Почини логин")
        #expect(chatName(name: "", message: "```swift\nlet x = 1\n```", existing: []) == "let x = 1")
        #expect(chatName(name: "", message: "\u{200B}\u{FEFF}\n\u{200D}Почини\u{200B} логин", existing: []) == "Почини логин")
        L10n.language = .ru
        defer { L10n.language = .system }
        // Nothing visible: «Чат N».
        #expect(chatName(name: "", message: "#\n> \n```\n\u{200B}", existing: []) == "Чат 1")
        #expect(chatName(name: "\u{200B}", message: "", existing: []) == "Чат 1")
    }

    @Test func longMessageIsCutAtAWord() {
        let message = "Добавь поле промокода в корзину и проверь, что скидка считается до налога"
        let name = chatName(name: "", message: message, existing: [])
        #expect(name == "Добавь поле промокода в корзину и")
        #expect(name.count <= chatNameMaxLength)
        // One long word: a hard cut.
        #expect(chatName(name: "", message: String(repeating: "a", count: 60), existing: []).count == chatNameMaxLength)
    }

    @Test func noMessageGivesTheNextFreeNumber() {
        L10n.language = .ru
        defer { L10n.language = .system }
        #expect(chatName(name: "", message: " \n ", existing: []) == "Чат 1")
        #expect(chatName(name: "", message: "", existing: ["Чат 1", "fix", "Чат 3"]) == "Чат 2")
        #expect(chatName(name: "", message: "", existing: ["Чат 1", "Чат 2"]) == "Чат 3")
        L10n.language = .en
        #expect(chatName(name: "", message: "", existing: ["Chat 1"]) == "Chat 2")
    }
}
