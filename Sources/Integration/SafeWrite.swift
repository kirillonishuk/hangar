import CryptoKit
import Foundation

/// File contents, or nil when it does not exist.
public func readUserFile(_ url: URL) throws -> String? {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
        return nil
    }
}

/// Follows a symlink chain to the real file so the link itself stays a link.
public func resolveLinks(_ url: URL) throws -> URL {
    var cur = url
    for _ in 0..<32 {
        guard let type = try? FileManager.default.attributesOfItem(atPath: cur.path)[.type] as? FileAttributeType,
              type == .typeSymbolicLink else { return cur }
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: cur.path)
        cur = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : cur.deletingLastPathComponent().appendingPathComponent(dest)
    }
    throw CocoaError(.fileReadUnknown)
}

/// Backups kept per file in a backup folder (`backupDir`); older ones are deleted.
public let keptBackups = 5

/// The folder for one file's backups under `root`: named by a hash of the file's path, so files in a repo never get
/// a backup beside them (it could be committed, secrets and all).
public func backupFolder(root: String, for path: String) -> String {
    let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return root + "/" + digest
}

/// Copies `target` to `<dir>/<name>.hangar-backup-<time>` (next to it when `backupDir` is nil); in a backup folder the
/// oldest beyond `keptBackups` are deleted. Returns the copy.
private func backUp(_ target: URL, backupDir: URL?, now: Date) throws -> URL {
    let fm = FileManager.default
    let dir = backupDir.map { URL(fileURLWithPath: backupFolder(root: $0.path, for: target.path)) } ?? target.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    let prefix = "\(target.lastPathComponent).hangar-backup-"
    let base = prefix + f.string(from: now)
    var candidate = dir.appendingPathComponent(base)
    var n = 2
    while fm.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base)-\(n)"); n += 1
    }
    try fm.copyItem(at: target, to: candidate)  // copyItem keeps the permissions: a backup may hold secrets
    if backupDir != nil {
        try? Data(target.path.utf8).write(to: dir.appendingPathComponent("source"))
        let old = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        for name in old.dropLast(keptBackups) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }
    return candidate
}

/// Writes a user's config: refuses if it changed since `expected` was read or is read-only, backs up the old bytes
/// (next to it, or in `backupDir`), re-checks right before the rename (abort keeps the backup, removes the temp),
/// replaces atomically, keeps the file's permissions (new file: 0600). Returns the backup URL, if one was made.
public func writeUserFile(_ url: URL, text: String, expected: String?, now: Date, backupDir: URL? = nil,
                         beforeRename: () -> Void = {}) throws -> URL? {
    let fm = FileManager.default
    let target = try resolveLinks(url)
    let current = try readUserFile(target)
    guard current == expected else { throw IntegrationError.changedOnDisk }
    if current != nil, access(target.path, W_OK) != 0 { throw IntegrationError.readOnly }
    let dir = target.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    var mode: mode_t = 0o600
    var backup: URL?
    if current != nil {
        mode = (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        backup = try backUp(target, backupDir: backupDir, now: now)
    }

    // Own temp + rename instead of Data.write(.atomic): the temp is created with the final mode, so secrets are never 0644.
    let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).hangar-\(UUID().uuidString)")
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
        try handle.close()
        _ = chmod(tmp.path, mode)  // open's mode is masked by umask
        beforeRename()  // test seam: simulates a concurrent edit
        guard try readUserFile(target) == expected else { throw IntegrationError.changedOnDisk }
        guard rename(tmp.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch {
        try? fm.removeItem(at: tmp)
        throw error
    }
    return backup
}

/// Removes a user's file that is still exactly `expected` (and writable), after a backup in `backupDir`.
public func removeUserFile(_ url: URL, expected: String, now: Date, backupDir: URL) throws -> URL {
    let target = try resolveLinks(url)
    guard try readUserFile(target) == expected else { throw IntegrationError.changedOnDisk }
    guard access(target.path, W_OK) == 0 else { throw IntegrationError.readOnly }
    let backup = try backUp(target, backupDir: backupDir, now: now)
    try FileManager.default.removeItem(at: target)
    return backup
}
