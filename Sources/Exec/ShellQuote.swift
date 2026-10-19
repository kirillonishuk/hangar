import Foundation
/// POSIX single-quote quoting; strings of only safe characters are returned bare.
public func shellQuote(_ s: String) -> String {
    let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
    if !s.isEmpty && s.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
