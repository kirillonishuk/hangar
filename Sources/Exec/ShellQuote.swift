import Foundation
/// POSIX single-quote quoting; strings of only safe characters are returned bare. Backslashes are escaped outside the
/// quotes so fish (a possible ssh login shell, which reads `\'` inside single quotes as a quote) parses it the same.
public func shellQuote(_ s: String) -> String {
    let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
    if !s.isEmpty && s.allSatisfy({ safe.contains($0) }) { return s }
    var out = "'"
    for c in s {
        switch c {
        case "'": out += "'\\''"
        case "\\": out += "'\\\\'"
        default: out.append(c)
        }
    }
    return out + "'"
}
