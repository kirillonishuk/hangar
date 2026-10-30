import Foundation

/// A name from the first message stays a sidebar-row length.
let chatNameMaxLength = 40

/// The chat's name (decision #116): «Название» trimmed; left empty — the first message's first non-empty line
/// (whitespace collapsed, cut at a word to `chatNameMaxLength`); no message either — «Чат N», the project's
/// smallest number not taken by a chat named so.
@MainActor func chatName(name: String, message: String, existing: [String]) -> String {
    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return typed }
    let lines = message.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    if let line = lines.first(where: { !$0.isEmpty }) {
        guard line.count > chatNameMaxLength else { return line }
        let cut = line.prefix(chatNameMaxLength + 1)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) }
        return String(line.prefix(chatNameMaxLength))
    }
    let taken = Set(existing)
    var n = 1
    while taken.contains(L10n.chatNumbered(n)) { n += 1 }
    return L10n.chatNumbered(n)
}
