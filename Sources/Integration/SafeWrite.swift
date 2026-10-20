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
private func resolveLinks(_ url: URL) throws -> URL {
    var cur = url
    for _ in 0..<32 {
        guard let type = try? FileManager.default.attributesOfItem(atPath: cur.path)[.type] as? FileAttributeType,
              type == .typeSymbolicLink else { return cur }
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: cur.path)
        cur = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : cur.deletingLastPathComponent().appendingPathComponent(dest)
    }
    throw CocoaError(.fileReadUnknown)
}

/// Writes a user's config: refuses if it changed since `expected` was read, backs up the old bytes next to it,
/// re-checks right before the rename (abort keeps the backup, removes the temp), replaces atomically, keeps the file's permissions (new file: 0600). Returns the backup URL, if one was made.
public func writeUserFile(_ url: URL, text: String, expected: String?, now: Date,
                         beforeRename: () -> Void = {}) throws -> URL? {
    let fm = FileManager.default
    let target = try resolveLinks(url)
    let current = try readUserFile(target)
    guard current == expected else { throw IntegrationError.changedOnDisk }
    let dir = target.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    var mode: mode_t = 0o600
    var backup: URL?
    if current != nil {
        mode = (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(target.lastPathComponent).hangar-backup-\(f.string(from: now))"
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n)"); n += 1
        }
        try fm.copyItem(at: target, to: candidate)  // copyItem keeps the permissions: a backup may hold secrets
        backup = candidate
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
