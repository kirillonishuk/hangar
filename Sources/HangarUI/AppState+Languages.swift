import Exec
import Foundation

/// tsserver for the editors (#NN-tsserver): the project's TypeScript, node from the login shell (here) or the host's login PATH.
extension AppState {
    func makeLanguages() -> Languages {
        Languages(
            lookup: { [weak self] host, dir, root in
                guard let self else { return .noTypeScript }
                guard let host else { return await TsInstall.localLookup(dir: dir, root: root) { await self.nodePath() } }
                guard let r = try? await self.remote.runner(host).run(["sh", "-c", TsMap.lookupScript, "sh", dir, root], "/") else {
                    return .notConnected
                }
                guard let found = TsMap.parseLookup(r.stdout) else { return .noTypeScript }
                return found.node.isEmpty ? .noNode : .found(TsInstall(found, node: found.node))
            },
            launch: { [weak self] host, install in
                let locale = L10n.resolve(L10n.language).rawValue
                guard let host else { return install.localLaunch(locale: locale) }
                guard let self, let target = self.remote.target(host),
                      let args = sshStreamArgs(host: host, controlPath: target.controlPath, path: self.remote.hosts[host]?.report?.path,
                                               cwd: install.cwd, argv: [install.node] + install.serverArgs(locale: locale)) else { return nil }
                return TsLaunch(executable: target.sshPath, args: args, cwd: "/")
            })
    }

    /// App quit: every tsserver gets `exit` and EOF.
    public func stopLanguages() { languages.stopAll() }

    /// The login shell's `node`, else the usual Homebrew places; nil when there is none.
    private func nodePath() async -> String? {
        if let localNode { return await localNode.value }
        let shell = posixShell(userShell)
        let task = Task<String?, Never> {
            let found: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    guard let r = try? await Runner.local.run([shell, "-l", "-i", "-c", "command -v node"], NSHomeDirectory()) else { return nil }
                    return r.stdout.split(whereSeparator: \.isNewline).map(String.init).last { $0.hasPrefix("/") }
                }
                group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let found, FileManager.default.isExecutableFile(atPath: found) { return found }
            return TsInstall.fallbackNodes.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        localNode = task
        let node = await task.value
        if node == nil { localNode = nil }  // installed later: the restart action finds it
        return node
    }
}
