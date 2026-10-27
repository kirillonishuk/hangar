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

    /// A host connected: an older `hangar-remote` first (the hooks call it), then the hooks, through the «Сервер» sheet's
    /// read and write. Off in DEBUG runs without a fake ssh (main.swift).
    func upgradeRemote(host: String) async {
        guard autoUpgradeRemote else { return }
        let m = ServerCheckModel(host: host, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: host))
        _ = await m.autoUpgradeRemoteScript()
        _ = await m.autoUpgradeClaude()
    }
}
