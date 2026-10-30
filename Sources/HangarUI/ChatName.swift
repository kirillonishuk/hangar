import Foundation

/// A name from the first message stays a sidebar-row length.
let chatNameMaxLength = 40

/// The chat's name (decision #116): «Название» trimmed (as typed: joiners make emoji and words); left empty — the first visible line of the message (markdown
/// markers and invisible characters dropped, whitespace collapsed, cut at a word to `chatNameMaxLength`); nothing
/// visible — «Чат N», the project's smallest number not taken by a chat named so.
@MainActor func chatName(name: String, message: String, existing: [String]) -> String {
    let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return typed }
    if let line = firstVisibleLine(message) {
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

/// Walks lines only up to the first one with text (runs on every keystroke into the prompt).
private func firstVisibleLine(_ message: String) -> String? {
    var rest = message[...]
    while !rest.isEmpty {
        let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
        let line = visible(rest[..<end])
        // A code fence line (```swift, ~~~) names nothing.
        if !line.hasPrefix("```"), !line.hasPrefix("~~~") {
            // Whole marker words only («#», «>», «-», «**»): «-1 bug» and «**bold**» stay as written.
            let text = line.split(separator: " ").drop { $0.allSatisfy { "#>*-+".contains($0) } }.joined(separator: " ")
            if !text.isEmpty { return text }
        }
        rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
    }
    return nil
}

/// Without invisible format/control characters (zero-width space, BOM, marks) but with ZWJ / ZWNJ (emoji, Persian),
/// whitespace collapsed and trimmed.
private func visible(_ text: Substring) -> String {
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: text.unicodeScalars.filter {
        let category = $0.properties.generalCategory
        return category != .format && category != .control || $0 == "\u{200C}" || $0 == "\u{200D}" || $0 == "\t"
    })
    return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
