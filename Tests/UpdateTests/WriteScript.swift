import CryptoKit
import Foundation

/// Puts an executable script at `path` as a hard link to a per-content copy shared by all tests and runs. macOS
/// security-scans every new executable on its first exec, one at a time (XprotectService); fresh per-test scripts
/// queue there for minutes in a full parallel run, a link to an already-scanned file is not scanned again.
/// Scripts find their test's files via `$0`, so the content (and the scan) is shared. Never write to `path` in
/// place afterwards: replace it (`atomically: true`, or `writeScript` again).
func writeScript(_ text: String, to path: String) throws {
    let fm = FileManager.default
    let cache = "/tmp/hangar-test-scripts-\(getuid())"
    try fm.createDirectory(atPath: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // A shared /tmp: only a private directory of this user may supply executables.
    let attrs = try fm.attributesOfItem(atPath: cache)
    guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
    else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: cache]) }
    let data = Data(text.utf8)
    let cached = cache + "/" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let intact = fm.contents(atPath: cached) == data
        && ((try? fm.attributesOfItem(atPath: cached)[.posixPermissions]) as? NSNumber)?.intValue == 0o755
    if !intact {
        let tmp = cached + "." + UUID().uuidString
        try data.write(to: URL(fileURLWithPath: tmp))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        _ = rename(tmp, cached)  // atomic; a parallel writer of the same content wins equally
        try? fm.removeItem(atPath: tmp)
    }
    try? fm.removeItem(atPath: path)
    guard link(cached, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
