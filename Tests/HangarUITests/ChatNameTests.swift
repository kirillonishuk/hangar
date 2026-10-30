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
        #expect(chatName(name: "", message: "\u{200B}\u{FEFF}\n\u{2060}Почини\u{200B} логин", existing: []) == "Почини логин")
        L10n.language = .ru
        defer { L10n.language = .system }
        // Nothing visible: «Чат N».
        #expect(chatName(name: "", message: "#\n> \n```\n\u{200B}", existing: []) == "Чат 1")
    }

    /// A typed name is only trimmed: joiners make emoji and Persian words.
    @Test func typedNameKeepsJoiners() {
        #expect(chatName(name: " 👨\u{200D}👩\u{200D}👧 ", message: "", existing: []) == "👨\u{200D}👩\u{200D}👧")
        #expect(chatName(name: "می\u{200C}خواهم", message: "", existing: []) == "می\u{200C}خواهم")
        #expect(chatName(name: "", message: "\u{200B}می\u{200C}خواهم 👨\u{200D}👩", existing: []) == "می\u{200C}خواهم 👨\u{200D}👩")
    }

    @Test func onlyWholeMarkersAreDropped() {
        #expect(chatName(name: "", message: "-1 bug", existing: []) == "-1 bug")
        #expect(chatName(name: "", message: "**Почини** логин", existing: []) == "**Почини** логин")
        #expect(chatName(name: "", message: "- ** Почини логин", existing: []) == "Почини логин")
        #expect(chatName(name: "", message: "#hashtag", existing: []) == "#hashtag")
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
