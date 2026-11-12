import Foundation
import Git

/// «Откатить изменения…» of a Changes row and the diff header (decision HD-156): confirm, snapshot, revert to HEAD (a
/// new file to the Trash), then the toast with «Вернуть».
extension AppState {
    /// The file has uncommitted changes (Changes in «Вся ветка» lists committed ones too: nothing to revert there).
    func canRevert(_ relative: String) -> Bool { inspector.badges[relative] != nil }

    /// What the sheet says goes away, by the file's uncommitted change.
    func revertInfo(_ relative: String) -> String {
        switch inspector.badges[relative] {
        case .untracked, .added: return L10n.revertInfoNew
        case .deleted: return L10n.revertInfoDeleted
        case .renamed: return L10n.revertInfoRenamed
        default:
            // The list's counts are against HEAD only in «Не в коммите».
            guard inspector.changes?.mode == .uncommitted,
                  let file = inspector.changes?.files.first(where: { $0.path == relative }) else { return L10n.revertInfoEdits }
            let counts = [file.added.flatMap { $0 > 0 ? "+\($0)" : nil }, file.deleted.flatMap { $0 > 0 ? "−\($0)" : nil }].compactMap { $0 }
            return counts.isEmpty ? L10n.revertInfoEdits : L10n.revertInfoCounts(counts.joined(separator: " "))
        }
    }

    /// Asks, then reverts `relative` (under the inspector's root). Refuses an unsaved editor or diff buffer of it.
    func requestRevert(_ relative: String) {
        guard let root = inspector.root, let project = selectedTask.flatMap({ project($0.projectId) }),
              selectedProjectIsLocal, canRevert(relative) else { return }
        let name = (relative as NSString).lastPathComponent
        // For the unsaved-buffer check only; the revert takes the old name from `git status` (`revert`).
        let origPath = inspector.badges[relative] == .renamed && inspector.changes?.mode == .uncommitted
            ? inspector.changes?.files.first(where: { $0.path == relative })?.origPath : nil
        let full = ([relative] + (origPath.map { [$0] } ?? [])).map { root + "/" + $0 }
        if !Set(unsavedEditorFiles() + (diffUnsavedPaths?() ?? [])).isDisjoint(with: full) {
            actionFailed?(L10n.revertUnsavedTitle(name), L10n.revertUnsavedInfo)
            return
        }
        confirmDestructive?(L10n.revertTitle(name), revertInfo(relative), L10n.revertButton) { [self] in
            revert(relative, git: git(for: project, repo: root))
        }
    }

    private func revert(_ relative: String, git: Git) {
        let name = (relative as NSString).lastPathComponent
        let backups = (socketPath as NSString).deletingLastPathComponent + "/reverted"
        Task {
            do {
                // A rename's old name against HEAD (the list in «Вся ветка» is against the branch's base); one outside the
                // project's subfolder stays as it is (a path outside it, relative to the top, would be the wrong file).
                var origPath: String?
                if inspector.badges[relative] == .renamed {
                    let prefix = try await git.location().prefix
                    let entry = try await git.status().entries.first { $0.path == prefix + relative }
                    origPath = entry?.origPath.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
                }
                let backup = try await git.revertFile(relative, origPath: origPath, backupRoot: backups)
                uiLog.info("reverted a file, backup \(backup.dir, privacy: .public)")
                inspector.refresh(.all)
                undoToast?(L10n.revertDone(name)) { [self] in
                    do { try backup.undo() } catch RevertError.changedSince {
                        actionFailed?(L10n.revertUndoFailed(name), L10n.revertUndoChanged + "\n" + backup.dir)
                    } catch {
                        actionFailed?(L10n.revertUndoFailed(name), error.localizedDescription + "\n" + backup.dir)
                    }
                    inspector.refresh(.all)
                }
            } catch {
                let details = switch error as? RevertError {
                case .notAFile: L10n.revertNotAFile
                case .nothingToRevert: L10n.revertNothing
                case .remote: L10n.revertRemote
                case let .afterSnapshot(dir, message): message + "\n" + L10n.revertSnapshotKept + "\n" + dir
                case let .changedWhileReverting(dir, _): L10n.revertChangedMeanwhile + "\n" + dir
                case .changedSince, nil: error.localizedDescription
                }
                actionFailed?(L10n.revertFailed(name), details)
                inspector.refresh(.all)
            }
        }
    }
}
