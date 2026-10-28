import Foundation
import Workspace

extension AppState {
    /// File access of an editor leaf (or the diff): through the host for a remote project.
    func editorIO(host: String?) -> EditorIO {
        guard let host else { return .local }
        let remote = self.remote
        return .remote(runner: remote.runner(host)) { script, args, input in
            await remote.write(host, script: script, args: args, input: input)
        }
    }

    func editorLeaf(_ id: UUID) -> Leaf? {
        for task in state.tasks where !task.archived {
            for tab in task.tabs { if let leaf = tab.root.leaf(id: id), leaf.kind == .editor { return leaf } }
        }
        return nil
    }

    /// Unsaved editor files of every open session's leaves: quitting asks first.
    func unsavedEditorFiles() -> [String] {
        let leaves = state.tasks.filter { !$0.archived }.flatMap(\.tabs).flatMap(\.root.leaves)
        return leaves.filter { $0.kind == .editor }.flatMap { editorUnsaved?($0.id) ?? [] }
    }
}

extension AppState {
    /// The status bar's tsserver item: restart (or look for TypeScript again) for the file tab's file.
    func restartLanguage(leafId: UUID) {
        guard let path = editorLeaf(leafId)?.openFile else { return }
        languages.restart(path, host: remoteLeafHost(leafId))
    }
}

extension AppState {
    /// Settings → Editor: saved to config.toml, applied to the open pages at once (#84).
    func setEditorAppearance(_ key: String, _ value: String? = nil, flag: Bool? = nil, apply: (inout HangarConfig) -> Void) throws {
        if let value { try setConfig(key, value, apply: apply) } else if let flag { try setConfig(key, flag: flag, apply: apply) }
        onEditorAppearance?(EditorAppearance(config))
    }
}
