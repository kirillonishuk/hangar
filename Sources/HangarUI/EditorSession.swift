import Foundation

/// The files of one editor tab on the Swift side: what was loaded (stamp), dirty, read-only, conflict; it reads and
/// saves through `EditorIO` and tells the page what to show through `send` (#80). The buffers live in Monaco.
@MainActor final class EditorSession {
    struct File {
        var stamp: FileStamp?
        var dirty = false
        var readOnly = false
        /// Not loaded (too large, binary, missing): the tab shows only its notice.
        var refused = false
        var conflict = false
    }

    let io: EditorIO
    let limits: EditorLimits
    private let send: (EditorCommand) -> Void
    private(set) var files: [String: File] = [:]
    /// A file's dirty flag changed (the tab's dot).
    var onDirty: ((String, Bool) -> Void)?
    /// An editable text file is now in the page (path, text): the language server gets it.
    var onOpened: ((String, String) -> Void)?

    init(io: EditorIO, limits: EditorLimits = EditorLimits(), send: @escaping (EditorCommand) -> Void) {
        self.io = io
        self.limits = limits
        self.send = send
    }

    func isDirty(_ path: String) -> Bool { files[path]?.dirty == true }
    func isReadOnly(_ path: String) -> Bool { files[path]?.readOnly == true }
    var anyDirty: Bool { files.values.contains { $0.dirty } }

    /// Loads the file into the page (once) and focuses it at the line / column.
    func open(path: String, line: Int?, column: Int?) async {
        if files[path] != nil {
            send(.activate(path: path, line: line, column: line == nil ? column : column ?? 1))
            return
        }
        // A second open while this one reads only activates; `refused` until loaded keeps disk checks and saves off it.
        files[path] = File(readOnly: true, refused: true)
        var open = EditorOpen(path: path, text: nil, readOnly: true, notice: nil, line: line ?? 1, column: column ?? 1)
        var file = File(readOnly: true, refused: true)
        do {
            switch try await io.read(path, limits.refuse) {
            case .text(let text, let stamp):
                let large = text.utf8.count > limits.editable
                // Go to definition lands in node_modules (or site-packages, the Go / Cargo caches): shown, never edited by accident.
                let dependency = LspMap.isDependency(path)
                open.text = text
                open.readOnly = large || dependency
                open.notice = large ? L10n.editorLargeReadOnly : dependency ? L10n.editorDependencyReadOnly : nil
                file = File(stamp: stamp, readOnly: large || dependency)
            case .tooLarge(let size): open.notice = L10n.editorTooLarge(size)
            case .binary: open.notice = L10n.editorBinary
            case .missing: open.notice = L10n.editorMissing
            }
        } catch {
            open.notice = L10n.editorReadFailed(String(describing: error))
        }
        guard files[path] != nil else { return }  // closed while reading
        files[path] = file
        send(.open(open))
        if let text = open.text, text.utf8.count <= limits.editable { onOpened?(path, text) }
    }

    /// The diff's working side: read here and tracked like an open file (the page gets it inside `.diff`).
    /// nil: not a text file the editor takes (missing, binary, too large).
    func adopt(path: String) async -> (text: String, readOnly: Bool)? {
        guard case .text(let text, let stamp)? = try? await io.read(path, limits.refuse) else { return nil }
        let large = text.utf8.count > limits.editable
        files[path] = File(stamp: stamp, readOnly: large)
        return (text, large)
    }

    /// An editor pane moved to the other Monaco page with this buffer (maybe unsaved): it opens there as it was.
    func adopt(path: String, text: String, file: File, line: Int?, column: Int?) {
        files[path] = file
        send(.open(EditorOpen(path: path, text: text, readOnly: file.readOnly, notice: nil, line: line ?? 1, column: column ?? 1,
                              dirty: file.dirty)))
        if file.conflict { send(.conflict(path: path, shown: true)) }
        if text.utf8.count <= limits.editable { onOpened?(path, text) }
    }

    func close(path: String) {
        files[path] = nil
    }

    func handle(_ message: BridgeMessage) async {
        switch message {
        case .changed(let path, let dirty):
            guard files[path] != nil, files[path]?.dirty != dirty else { return }
            files[path]?.dirty = dirty
            onDirty?(path, dirty)
        case .save(let path, let text): await save(path, text)
        case .conflict(let path, let keepMine):
            guard files[path]?.conflict == true else { return }
            files[path]?.conflict = false
            send(.conflict(path: path, shown: false))
            if keepMine {
                if let current = try? await io.stat(path) { files[path]?.stamp = current }
            } else {
                await reload(path)
            }
        default: break
        }
    }

    private func save(_ path: String, _ text: String) async {
        guard let file = files[path], !file.readOnly, !file.refused else { return }
        guard !file.conflict else { send(.conflict(path: path, shown: true)); return }
        do {
            // Changed on disk since the load (no watcher event yet, or a server): ask instead of overwriting.
            if let current = try await io.stat(path), current != file.stamp {
                files[path]?.conflict = true
                send(.conflict(path: path, shown: true))
                return
            }
            let stamp = try await io.write(path, text)
            guard files[path] != nil else { return }
            files[path]?.stamp = stamp
            files[path]?.dirty = false
            onDirty?(path, false)
            send(.saved(path: path))
        } catch {
            send(.notice(path: path, text: L10n.editorSaveFailed(String(describing: error))))
        }
    }

    /// Re-stats the open files (FSEvents for local ones, focus for remote): clean buffers reload, dirty ones get the bar.
    func checkDisk(_ only: Set<String>? = nil) async {
        for (path, file) in files where !file.refused && (only?.contains(path) ?? true) {
            guard let current = try? await io.stat(path), let latest = files[path] else { continue }
            switch diskChange(loaded: latest.stamp, current: current, dirty: latest.dirty) {
            case .none: break
            case .reload: await reload(path)
            case .conflict:
                guard !latest.conflict else { continue }
                files[path]?.conflict = true
                send(.conflict(path: path, shown: true))
            }
        }
    }

    private func reload(_ path: String) async {
        guard case .text(let text, let stamp)? = try? await io.read(path, limits.refuse), files[path] != nil else { return }
        files[path]?.stamp = stamp
        files[path]?.dirty = false
        onDirty?(path, false)
        send(.reload(path: path, text: text))
    }
}
