import Foundation
import os

public enum LoadResult: Equatable, Sendable {
    case empty
    case loaded(WorkspaceState)
    case recoveredFromCorrupt(backup: URL)
    case unreadable(URL)
}

/// Persists `WorkspaceState` to `directory/state.json`: atomic writes, debounced saves,
/// corrupt files (and a dangling symlink) moved to `state.json.bak`. Main-actor isolated; no timers (a sleeping Task only while a save is pending).
@MainActor
public final class StateStore {
    private let directory: URL
    private let debounce: Duration
    /// The debounced save waiting to run; nil when none (test seam: tests await it).
    private(set) var pending: Task<Void, Never>?
    private var readOnly = false
    private static let log = Logger(subsystem: "dev.hangar", category: "StateStore")

    /// Test seams.
    var writeHook: ((Data) -> Void)?
    var encode: (WorkspaceState) throws -> Data = { state in
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    public init(directory: URL, debounce: Duration = .milliseconds(500)) {
        self.directory = directory
        self.debounce = debounce
    }

    private var fileURL: URL { directory.appendingPathComponent("state.json") }
    private var backupURL: URL { directory.appendingPathComponent("state.json.bak") }

    public func load() -> LoadResult {
        readOnly = false
        let fm = FileManager.default
        // attributesOfItem does not follow a final symlink: a dangling state.json is "there" but corrupt.
        guard (try? fm.attributesOfItem(atPath: fileURL.path)) != nil else { return .empty }
        if fm.fileExists(atPath: fileURL.path) {
            let data: Data
            do { data = try Data(contentsOf: fileURL) } catch {
                return lockDown("cannot read state.json: \(error)")
            }
            if let state = try? JSONDecoder().decode(WorkspaceState.self, from: data) {
                return .loaded(state)
            }
        }
        // rename(2) moves the item itself (a symlink stays a link) and atomically replaces an older .bak.
        guard rename(fileURL.path, backupURL.path) == 0 else {
            return lockDown("cannot back up corrupt state.json: \(String(cString: strerror(errno)))")
        }
        return .recoveredFromCorrupt(backup: backupURL)
    }

    /// Existing file can't be read or backed up: never write, so the user's file is not overwritten.
    private func lockDown(_ message: String) -> LoadResult {
        readOnly = true
        Self.log.error("\(message, privacy: .public); state store is read-only")
        return .unreadable(fileURL)
    }

    /// Replaces any pending debounced save; writes after `debounce` of quiet.
    public func scheduleSave(_ state: WorkspaceState) {
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            do { try self.write(state) } catch {
                Self.log.error("state save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Writes immediately (cancels any pending debounced save).
    public func saveNow(_ state: WorkspaceState) throws {
        pending?.cancel()
        pending = nil
        try write(state)
    }

    private func write(_ state: WorkspaceState) throws {
        guard !readOnly else {
            Self.log.error("save skipped: state store is read-only")
            return
        }
        let data = try encode(state)
        ensurePrivateDirectory(directory, tightenExisting: directory.standardizedFileURL.path == defaultStateDirectoryPath())
        try data.write(to: fileURL, options: .atomic)
        writeHook?(data)
    }
}

/// The default state directory (release path); only this one may be chmod-ed when it already exists.
public func defaultStateDirectoryPath() -> String { NSHomeDirectory() + "/Library/Application Support/Hangar" }

/// The state directory holds the control socket and the session ids: owner-only (0700).
/// A pre-existing directory is tightened only when `tightenExisting` (the default state dir), it is ours,
/// and group/other can access it; intermediate directories get default permissions.
public func ensurePrivateDirectory(_ url: URL, tightenExisting: Bool) {
    let fm = FileManager.default
    var st = stat()
    if lstat(url.path, &st) == 0 {
        if tightenExisting, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 != 0 {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return
    }
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
}
