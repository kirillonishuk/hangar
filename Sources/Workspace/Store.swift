import Foundation

public enum LoadResult: Equatable, Sendable {
    case empty
    case loaded(WorkspaceState)
    case recoveredFromCorrupt(backup: URL)
}

/// Persists `WorkspaceState` to `directory/state.json`: atomic writes, debounced saves,
/// corrupt files moved to `state.json.bak`. Main-actor isolated; no timers (a sleeping Task only while a save is pending).
@MainActor
public final class StateStore {
    private let directory: URL
    private let debounce: Duration
    private var pending: Task<Void, Never>?

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
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        if let state = try? JSONDecoder().decode(WorkspaceState.self, from: data) {
            return .loaded(state)
        }
        try? FileManager.default.removeItem(at: backupURL)
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
        } catch {
            FileHandle.standardError.write(Data("Hangar: cannot back up corrupt state.json: \(error)\n".utf8))
        }
        return .recoveredFromCorrupt(backup: backupURL)
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
                FileHandle.standardError.write(Data("Hangar: state save failed: \(error)\n".utf8))
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
        let data = try encode(state)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        writeHook?(data)
    }
}
