import Foundation

/// Concrete host names from `Host` lines of an ssh config, in file order, without duplicates; patterns (`*`, `?`),
/// negations (`!`) and names that `validSSHHost` rejects are skipped.
/// shortcut: `Include` is not followed; read the included files when users ask for it.
public func sshConfigHosts(_ text: String) -> [String] {
    var hosts: [String] = [], seen = Set<String>()
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let end = line.firstIndex(where: { $0 == "=" || $0.isWhitespace }),
              line[..<end].lowercased() == "host" else { continue }
        var rest = line[end...].drop(while: \.isWhitespace)
        if rest.first == "=" { rest = rest.dropFirst() }
        for word in rest.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.hasPrefix("#") { break }  // trailing comment
            if !word.contains(where: { "*?!#\"".contains($0) }), validSSHHost(word) != nil, seen.insert(word).inserted {
                hosts.append(word)
            }
        }
    }
    return hosts
}
