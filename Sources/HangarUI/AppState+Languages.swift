import Exec
import Foundation

/// tsserver for the editors (#82): the project's TypeScript, node from the login shell (here) or the host's login PATH.
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
            },
            lsp: LspLanguages(find: { [weak self] language, root in
                let path = await self?.loginShellPath()
                return await LspMap.find(language, projectRoot: root, path: (path ?? "").split(separator: ":").map(String.init),
                                         home: NSHomeDirectory(), isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                                         toolchain: xcrunFind)
            }, path: { [weak self] in await self?.loginShellPath() }, dependencies: { [weak self] language in
                await toolchainRoots(language, path: await self?.loginShellPath())
            }))
    }

    /// App quit: every tsserver gets `exit` and EOF.
    public func stopLanguages() { languages.stopAll() }

    /// The login shell's PATH (nil: it didn't answer in 15 s; looked up again next time).
    private func loginShellPath() async -> String? {
        if let loginPath { return await loginPath.value }
        let shell = posixShell(userShell)
        let task = Task<String?, Never> {
            await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    guard let r = try? await Runner.local.run([shell, "-l", "-i", "-c", #"printf '\nHANGAR-PATH=%s\n' "$PATH""#],
                                                              NSHomeDirectory()) else { return nil }
                    let dirs = LspMap.parsePath(r.stdout)
                    return dirs.isEmpty ? nil : dirs.joined(separator: ":")
                }
                group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        loginPath = task
        let path = await task.value
        if path == nil { loginPath = nil }
        return path
    }

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

/// A developer tool from the active Xcode / Command Line Tools (sourcekit-lsp); nil without them — `xcode-select -p`
/// goes first, so a Mac without them never gets the install dialog.
private func xcrunFind(_ name: String) async -> String? {
    guard let dir = try? await Runner.local.run(["/usr/bin/xcode-select", "-p"], "/"), dir.status == 0,
          let r = try? await Runner.local.run(["/usr/bin/xcrun", "--find", name], "/"), r.status == 0 else { return nil }
    return r.stdout.split(whereSeparator: \.isNewline).first.map(String.init)
}

/// Sources a definition may land in outside the project: Go's standard library (`go env GOROOT`, with the login
/// PATH) and the Xcode developer folder (SDKs, toolchains). Empty when there is none.
private func toolchainRoots(_ language: LspLanguage, path: String?) async -> [String] {
    let first = { (r: RunResult?) in r.flatMap { $0.status == 0 ? $0.stdout.split(whereSeparator: \.isNewline).first.map(String.init) : nil } }
    switch language.id {
    case "go":
        let env = path.map { ["PATH=" + $0] } ?? []
        return [first(try? await Runner.local.run(env + ["go", "env", "GOROOT"], "/"))].compactMap { $0 }
    case "swift":
        return [first(try? await Runner.local.run(["/usr/bin/xcode-select", "-p"], "/"))].compactMap { $0 }
    default: return []
    }
}
