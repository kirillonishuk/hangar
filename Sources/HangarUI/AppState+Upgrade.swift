import Foundation
import Integration

/// Automatic additive upgrade of an installed Claude integration (#96): Hangar's missing hooks only, never the user's.
extension AppState {
    public func upgradeClaudeHooksAtLaunch() async { await upgradeClaudeHooks(cli: hangarCLIPath(bundle: .main)) }

    /// Launch: the bundled CLI's hooks in this Mac's settings. Errors are logged; Settings then shows «устарела».
    func upgradeClaudeHooks(cli: String?) async {
        guard let cli, !installBlocked(cli: cli) else { return }
        let url = await doctorAgentPaths().claude
        do {
            if let backup = try claudeUpgradeFile(url, cli: cli, now: Date()) {
                uiLog.info("claude hooks upgraded, backup \(backup.path, privacy: .public)")
            }
        } catch {
            uiLog.error("claude hooks upgrade: \(String(describing: error), privacy: .public)")
        }
    }

    /// A host connected: the same on the server, through the «Сервер» sheet's read and write.
    func upgradeClaudeHooks(host: String) async {
        _ = await ServerCheckModel(host: host, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: host)).autoUpgradeClaude()
    }
}
