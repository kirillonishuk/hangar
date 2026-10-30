import ControlServer
import Exec
import Foundation
import Integration
import Testing
@testable import HangarUI
import Workspace
import TestSupport

/// The «Сервер» and «Удалённый проект» sheets' models on the RemoteHostsTests harness (fake ssh only, never a real host).
/// No install command is ever executed here: the terminal spec is only inspected.
@MainActor @Suite struct ServerCheckModelTests {
    typealias Harness = RemoteHostsTests.Harness

    final class Runs {
        var steps: [InstallStep] = []
        var inputs: [Data?] = []
    }

    /// A stub tool in the fake server's PATH that prints `version`.
    private func stub(_ h: Harness, _ name: String, version: String = "1.0") async throws {
        let path = h.bin + "/" + name
        try writeScript("#!/bin/sh\necho '\(name) \(version)'\n", to: path)
        try await RemoteHostsTests.run(path, ["-V"])  // the first exec of a fresh script is slow
    }

    /// shellQuote's per-character escaping without the outer quotes: one more level of `'…'` around `s`.
    private func escaped(_ s: String) -> String { String(shellQuote(s).dropFirst().dropLast()) }

    @Test func cancelRunsNothing() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        try? FileManager.default.removeItem(atPath: h.log)
        let runs = Runs()
        let m = ServerCheckModel(host: "dev", remote: h.remote) { step, data in
            runs.steps.append(step)
            return RunResult(status: 0, stdout: "", stderr: "")
        }
        await m.refresh()
        #expect(m.phase == .ready)
        #expect(m.plan.steps.contains { $0.title == "hangar-remote" })
        // Closing the sheet now: only the check and reads of the two integration files went to the server.
        // A multi-line argument spans several log lines: one call = all its lines.
        let calls = FakeSSH.calls(h.log).map { $0.joined(separator: "\n") }
        #expect(calls.filter { $0.contains("HANGAR_CHECK") }.count == 1)
        #expect(calls.allSatisfy { $0.contains("HANGAR_CHECK") || $0.contains("exec cat -- ") })
        #expect(runs.steps.isEmpty)
    }

    /// A missing codex is offered unticked: not in the plan (nor «install yourself») until ticked, out again when unticked.
    @Test func optionalToolsAreOptIn() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        await m.refresh()
        try #require(m.missingOptional.contains(.codex))
        let mentionsCodex = { m.plan.steps.contains { $0.title == "codex" } || m.plan.manual.contains(.codex) }
        #expect(m.optional.isEmpty)
        #expect(!mentionsCodex())
        m.optional.insert(.codex)
        #expect(mentionsCodex())
        m.optional.remove(.codex)
        #expect(!mentionsCodex())
    }

    @Test func installRunsShownScript() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        for tool in ["tmux", "codex"] { try await stub(h, tool) }
        #expect(await h.remote.connect("dev") == .connected)
        let runs = Runs()
        let write = ServerCheckModel.sshRun(remote: h.remote, host: "dev")
        let m = ServerCheckModel(host: "dev", remote: h.remote) { step, data in
            runs.steps.append(step)
            runs.inputs.append(data)
            return await write(step, data)
        }
        await m.refresh()
        // claude is missing (curl is there): one terminal step, then hangar-remote over stdin.
        #expect(m.plan.steps.map(\.title) == ["claude", "hangar-remote"])
        let spec = try #require(m.terminalSpec())
        #expect(spec.command.contains(escaped(escaped(shellQuote(terminalScript(m.plan.steps))))))
        #expect(spec.command.contains(escaped(shellQuote(h.ssh))) || spec.command.contains(h.ssh))
        #expect(spec.command.contains(" -t "))
        #expect(runs.steps.isEmpty)

        let master = try #require(h.pid("master-dev.pid"))
        m.startInstall()
        #expect(m.phase == .installing)
        try await stub(h, "claude")  // as if the terminal had installed it
        await m.installFinished(code: 0)
        #expect(runs.steps == [m.confirmedSteps.first { !$0.inTerminal }!])
        #expect(runs.steps.first?.title == "hangar-remote")
        #expect(runs.inputs == [Data(hangarRemoteScript.utf8)])
        let file = h.home + "/.hangar/bin/hangar-remote"
        #expect(try String(contentsOfFile: file, encoding: .utf8) == hangarRemoteScript)
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        #expect(m.report?.remoteVersion == hangarRemoteVersion)
        #expect(m.plan.steps.isEmpty)
        #expect(m.phase == .ready)
        // The writes and the check go over the master; it stays up.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(h.alive(master))
        #expect(h.state() == .connected)
    }

    @Test func failedTerminalWritesNothing() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let runs = Runs()
        let m = ServerCheckModel(host: "dev", remote: h.remote) { step, _ in
            runs.steps.append(step)
            return RunResult(status: 0, stdout: "", stderr: "")
        }
        await m.refresh()
        m.startInstall()
        await m.installFinished(code: 1)
        #expect(runs.steps.isEmpty)
        #expect(m.phase == .failed(L10n.installFailed(1)))
    }

    /// #111: the agent's file on the server through the checked write; off takes Hangar's entries out; no agent → nothing.
    @Test func applyAgentWritesAndRemoves() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        await m.refresh()
        let cli = h.home + "/.hangar/bin/hangar-remote"
        let settings = h.home + "/.claude/settings.json"
        // No file yet: created, no backup.
        #expect(await m.applyAgent(.claude, hooks: true, statusline: true) != .failed(""))
        let installed = try String(contentsOfFile: settings, encoding: .utf8)
        #expect(installed.contains(shellQuote(cli) + " event prompt"))
        #expect(claudeState(installed, cli: cli) == .installed)
        // Current: nothing written.
        #expect(await m.applyAgent(.claude, hooks: true, statusline: true) == .done(changed: nil, backup: nil))
        // Off: Hangar's entries go, after a backup next to the file.
        guard case .done(_, let backup?) = await m.applyAgent(.claude, hooks: false, statusline: false) else { Issue.record(); return }
        #expect(backup.hasPrefix("dev:" + h.home + "/.claude/settings.json.hangar-backup-"))
        #expect(claudeState(try String(contentsOfFile: settings, encoding: .utf8), cli: cli) == .notInstalled)
        // codex is not on this server: nothing written.
        #expect(await m.applyAgent(.codex, hooks: true, statusline: true) == .noAgent)
        #expect(!FileManager.default.fileExists(atPath: h.home + "/.codex/config.toml"))
        // Nothing local was touched.
        #expect(!FileManager.default.fileExists(atPath: h.root + "/.claude"))
    }

    @Test func symlinkedFileBacksUpNextToTarget() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        let fm = FileManager.default
        try fm.createDirectory(atPath: h.home + "/dotfiles", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: h.home + "/.claude", withIntermediateDirectories: true)
        try "{}\n".write(toFile: h.home + "/dotfiles/settings.json", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: h.home + "/.claude/settings.json", withDestinationPath: "../dotfiles/settings.json")
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        await m.refresh()
        guard case .done(_, _?) = await m.applyAgent(.claude, hooks: true, statusline: true) else { Issue.record(); return }
        #expect(try fm.contentsOfDirectory(atPath: h.home + "/dotfiles").contains { $0.hasPrefix("settings.json.hangar-backup-") })
        let type = try fm.attributesOfItem(atPath: h.home + "/.claude/settings.json")[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
    }

    /// The pre-#96 hook set for `cli` around a user hook: no PermissionRequest, StopFailure only for `rate_limit`.
    private func oldInstall(cli: String) throws -> String {
        let fresh = try claudeInstall(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#, cli: cli)
        guard case .object(var root) = try parseJSON(fresh), let i = root.firstIndex(where: { $0.key == "hooks" }),
              case .object(let events) = root[i].value else { throw IntegrationError.notAnObject }
        root[i].value = .object(events.filter { $0.key != "PermissionRequest" })
        return printJSON(.object(root)).replacingOccurrences(of: "\"StopFailure\": [\n      {\n", with: "\"StopFailure\": [\n      {\n        \"matcher\": \"rate_limit\",\n")
    }

    private func backups(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("settings.json.hangar-backup-") }
    }

    /// The connect of an agreed host (#96, #111): only the missing hooks, after a backup; again: nothing written.
    @Test func connectUpgradesInstalledClaudeHooks() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        try h.app.editConfig({ HangarConfig.updating(HangarConfig.updating($0, key: "claude_integration", literal: "true"),
                                                     key: "integration_hosts", literal: "[\"dev\"]") }) {
            $0.claudeIntegration = true
            $0.integrationHosts = ["dev"]
        }
        let cli = h.home + "/.hangar/bin/hangar-remote", dir = h.home + "/.claude", settings = dir + "/settings.json"
        let old = try oldInstall(cli: cli)
        #expect(old.contains("rate_limit"))
        #expect(claudeState(old, cli: cli) == .outdated)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try old.write(toFile: settings, atomically: true, encoding: .utf8)

        #expect(await h.remote.connect("dev") == .connected)
        let expected = try #require(try claudeApply(old, cli: cli, hooks: true, statusline: true, ours: remoteOwnership(cli: cli)))
        #expect(await waitUntil { (try? String(contentsOfFile: settings, encoding: .utf8)) == expected })
        #expect(await waitUntil { backups(dir).count == 1 })
        let backup = try #require(backups(dir).first)
        #expect(try String(contentsOfFile: dir + "/" + backup, encoding: .utf8) == old)
        #expect(claudeState(expected, cli: cli) == .installed)
        #expect(await waitUntil { h.app.hostMark(.claude, "dev") != .offline })

        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        #expect(await m.applyAgent(.claude, hooks: true, statusline: true) == .done(changed: nil, backup: nil))
        #expect(backups(dir).count == 1)
        #expect(!FileManager.default.fileExists(atPath: h.root + "/.claude"))
    }

    @Test func brokenFileIsLeftAlone() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        let cli = h.home + "/.hangar/bin/hangar-remote", dir = h.home + "/.claude", settings = dir + "/settings.json"
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = String(try oldInstall(cli: cli).dropLast(4))
        try text.write(toFile: settings, atomically: true, encoding: .utf8)
        guard case .failed = await m.applyAgent(.claude, hooks: true, statusline: true) else { Issue.record(); return }
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == text)
        #expect(backups(dir).isEmpty)
    }

    private func claudeOn(_ h: Harness) throws {
        try h.app.editConfig({ HangarConfig.updating($0, key: "claude_integration", literal: "true") }) { $0.claudeIntegration = true }
    }

    /// #111: a new host with nothing of Hangar's asks first (nothing written); «Подключить» installs `hangar-remote` and the
    /// hooks and remembers the host; its waiting tabs are let go.
    @Test func newHostAsksThenConnects() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        try claudeOn(h)
        let settings = h.home + "/.claude/settings.json"
        var answered = 0
        h.app.onIntegrationAnswered = { answered += 1 }
        #expect(await h.remote.connect("dev") == .connected)
        #expect(await waitUntil { h.app.integrations.ask == .host("dev") })
        #expect(!FileManager.default.fileExists(atPath: settings))
        #expect(h.app.hostMark(.claude, "dev") == .undecided)

        await h.app.answerHost("dev", connect: true)
        #expect(h.app.config.integrationHosts == ["dev"])
        #expect(try String(contentsOfFile: h.home + "/.hangar/bin/hangar-remote", encoding: .utf8) == hangarRemoteScript)
        #expect(claudeState(try String(contentsOfFile: settings, encoding: .utf8), cli: h.home + "/.hangar/bin/hangar-remote") == .installed)
        #expect(h.app.hostMark(.claude, "dev") != .offline)
        #expect(h.app.integrations.ask == nil)
        #expect(answered >= 1)
        #expect(!FileManager.default.fileExists(atPath: h.root + "/.claude"))
    }

    /// The upload of `hangar-remote` fails: no hooks pointing at a missing script, the host shows the error.
    @Test func noRemoteScriptNoHooks() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        try claudeOn(h)
        h.app.setHostDecision("dev", connect: false)  // the connect itself writes nothing; the apply below runs by hand
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 1, stdout: "", stderr: "disk full") }
        await h.app.applyHost("dev", m)
        #expect(h.app.integrations.marks[.claude]?["dev"] == .failed(L10n.intRemoteMissing))
        #expect(!FileManager.default.fileExists(atPath: h.home + "/.claude/settings.json"))
    }

    @Test func skippedHostIsLeftAlone() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        try claudeOn(h)
        h.app.setHostDecision("dev", connect: false)
        #expect(await h.remote.connect("dev") == .connected)
        await h.app.integrateHost("dev")
        #expect(h.app.integrations.ask == nil)
        #expect(!FileManager.default.fileExists(atPath: h.home + "/.claude/settings.json"))
        #expect(h.app.hostMark(.claude, "dev") == .skipped)
    }

    /// A host an older Hangar set up joins silently and is upgraded.
    @Test func olderInstallJoinsSilently() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try await stub(h, "claude")
        try claudeOn(h)
        let cli = h.home + "/.hangar/bin/hangar-remote", dir = h.home + "/.claude", settings = dir + "/settings.json"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try oldInstall(cli: cli).write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(await h.remote.connect("dev") == .connected)
        #expect(await waitUntil { h.app.config.integrationHosts == ["dev"] })
        #expect(await waitUntil { claudeState(try? String(contentsOfFile: settings, encoding: .utf8), cli: cli) == .installed })
        #expect(h.app.integrations.ask == nil)
    }

    private func installScript(_ h: Harness, _ text: String) throws -> String {
        let path = h.home + "/.hangar/bin/hangar-remote"
        try FileManager.default.createDirectory(atPath: h.home + "/.hangar/bin", withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    /// R7: an installed older `hangar-remote` is Hangar's own file, replaced on connect through the checked write.
    @Test func connectUpgradesOlderRemoteScript() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let old = "#!/bin/sh\n# hangar-remote \(hangarRemoteVersion - 1)\nexit 0\n"
        let path = try installScript(h, old)
        #expect(await h.remote.connect("dev") == .connected)
        #expect(await waitUntil { (try? String(contentsOfFile: path, encoding: .utf8)) == hangarRemoteScript })
        #expect(await waitUntil { h.remote.hosts["dev"]?.report?.remoteVersion == hangarRemoteVersion })
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: h.home + "/.hangar/bin")
        let backup = try #require(names.first { $0.hasPrefix("hangar-remote.hangar-backup-") })
        #expect(try String(contentsOfFile: h.home + "/.hangar/bin/" + backup, encoding: .utf8) == old)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        #expect(await m.autoUpgradeRemoteScript() == false)  // current now
    }

    @Test func remoteScriptNotInstalledOrNewerIsLeftAlone() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        #expect(await m.autoUpgradeRemoteScript() == false)
        #expect(!FileManager.default.fileExists(atPath: h.home + "/.hangar/bin/hangar-remote"))
        let newer = "#!/bin/sh\n# hangar-remote \(hangarRemoteVersion + 1)\n"
        let path = try installScript(h, newer)
        await h.remote.recheck("dev")
        #expect(await m.autoUpgradeRemoteScript() == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == newer)
    }

    /// DEBUG runs without a fake ssh (`autoUpgradeRemote` false) never write a server's files.
    @Test func remoteUpgradeOffWritesNothing() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        h.app.autoUpgradeRemote = false
        let cli = h.home + "/.hangar/bin/hangar-remote", settings = h.home + "/.claude/settings.json"
        let old = "#!/bin/sh\n# hangar-remote \(hangarRemoteVersion - 1)\n"
        let path = try installScript(h, old)
        try FileManager.default.createDirectory(atPath: h.home + "/.claude", withIntermediateDirectories: true)
        let hooks = try oldInstall(cli: cli)
        try hooks.write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(await h.remote.connect("dev") == .connected)
        await h.app.integrateHost("dev")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == old)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == hooks)
    }

    @Test func remoteProjectFindsPath() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try FileManager.default.createDirectory(atPath: h.home + "/proj", withIntermediateDirectories: true)
        var released: [String] = []
        let m = RemoteProjectModel(remote: h.remote, configHosts: ["dev"], release: { released.append($0) })
        m.host = "dev"
        m.path = "~/proj"
        await m.connect()
        let real = try #require(realpath(h.home + "/proj", nil).map { p in defer { free(p) }; return String(cString: p) })
        #expect(m.phase == .found(real))
        #expect(m.canAdd)
        #expect(m.server?.report != nil)

        m.path = "~/missing"
        #expect(!m.canAdd)
        await m.connect()
        #expect(m.phase == .failed(L10n.remotePathMissing, mono: false))
        #expect(m.pathInvalid && !m.hostInvalid)  // the folder's field is marked, not the host's

        // Another host: its login is refused (auth) → the readable hint; cancelling lets both hosts go.
        try h.flag("fail", "auth")
        m.host = "other"
        #expect(released == ["dev"])
        await m.connect()
        #expect(m.phase == .failed(L10n.sshAuthFailed("other"), mono: false))
        #expect(m.hostInvalid && !m.pathInvalid)
        m.cancel()
        #expect(released == ["dev", "other"])
    }

    @Test func unsupportedShellIsReadable() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        try (h.bin + "/tcsh").write(toFile: h.root + "/shell", atomically: true, encoding: .utf8)
        #expect(await h.remote.connect("dev") != .connected)
        #expect(h.remote.hosts["dev"]?.unsupportedShell == h.bin + "/tcsh")
        #expect(hostFailure("dev", h.remote.hosts["dev"]) == (L10n.unsupportedShell(h.bin + "/tcsh"), false))
    }

    @Test func hostLabels() {
        func label(_ s: HostState, paused: Bool = false) -> String {
            var info = HostInfo()
            info.state = s
            info.retryPaused = paused
            return hostStatusLabel(info)
        }
        #expect(label(.connected) == L10n.hostConnected)
        #expect(label(.connecting) == L10n.hostConnecting)
        #expect(label(.reconnecting(attempt: 2)) == L10n.hostReconnecting)
        // No timer runs while paused: nothing suggests a retry is going on.
        #expect(label(.reconnecting(attempt: 2), paused: true) == L10n.hostPaused)
        #expect(label(.unreachable("x")) == L10n.hostUnreachable)
        #expect(label(.disconnected) == L10n.hostDisconnected)
        #expect(hostStatusLabel(nil) == L10n.hostDisconnected)
    }

    @Test func pausedRetryIsMarked() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        h.active = false
        h.killMaster()
        #expect(await waitUntil { h.state() == .reconnecting(attempt: 1) })
        #expect(h.remote.hosts["dev"]?.retryPaused == true)
        #expect(h.scheduled.isEmpty)
        h.active = true
        h.remote.appBecameActive()
        #expect(h.remote.hosts["dev"]?.retryPaused == false)
    }
}
