import Foundation

/// A name from the first message stays a sidebar-row length.
let chatNameMaxLength = 40

/// The chat's name (decision #116): «Название» cleaned; left empty — the first visible line of the message (markdown
/// markers and invisible characters dropped, whitespace collapsed, cut at a word to `chatNameMaxLength`); nothing
/// visible — «Чат N», the project's smallest number not taken by a chat named so.
@MainActor func chatName(name: String, message: String, existing: [String]) -> String {
    let typed = visible(Substring(name))
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
        if !line.isEmpty, !line.hasPrefix("```"), !line.hasPrefix("~~~") {
            let text = String(line.drop { "#>*-+ ".contains($0) })
            if !text.isEmpty { return text }
        }
        rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
    }
    return nil
}

/// Without format/control characters (zero-width space, joiners, BOM), whitespace collapsed and trimmed.
private func visible(_ text: Substring) -> String {
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: text.unicodeScalars.filter {
        $0.properties.generalCategory != .format && $0.properties.generalCategory != .control || $0 == "\t"
    })
    return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
