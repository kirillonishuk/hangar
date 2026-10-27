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
        #expect(calls.allSatisfy { $0.contains("HANGAR_CHECK") || $0.contains(" '' cat ") })
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

    @Test func remoteIntegrationDiffAndWrite() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        await m.refresh()
        let cli = h.home + "/.hangar/bin/hangar-remote"
        let settings = h.home + "/.claude/settings.json"
        #expect(m.claude == .notInstalled)  // no file yet
        #expect(m.codex == nil)  // codex is not on this server

        let plan = try #require(await m.integrationPlan(.claude, install: true))
        #expect(plan.original == nil)
        #expect(plan.updated.contains(shellQuote(cli) + " event prompt"))
        #expect(plan.displayPath?.hasPrefix("dev:") == true)
        #expect(plan.displayPath == "dev:" + settings)
        #expect(await m.applyIntegration(plan))
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == plan.updated)
        #expect(m.claude == .installed)
        // Nothing local was touched.
        #expect(!FileManager.default.fileExists(atPath: h.root + "/.claude"))

        // The file changes between the plan and the write: nothing is written.
        let removal = try #require(await m.integrationPlan(.claude, install: false))
        #expect(removal.original == plan.updated)
        try (plan.updated + "\n").write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(await m.applyIntegration(removal) == false)
        #expect(m.integrationError == L10n.fileChanged)
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == plan.updated + "\n")

        // An existing file gets a backup next to it first.
        let fresh = try #require(await m.integrationPlan(.claude, install: false))
        #expect(await m.applyIntegration(fresh))
        let names = try FileManager.default.contentsOfDirectory(atPath: h.home + "/.claude")
        let backup = try #require(names.first { $0.hasPrefix("settings.json.hangar-backup-") })
        #expect(try String(contentsOfFile: h.home + "/.claude/" + backup, encoding: .utf8) == plan.updated + "\n")
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == fresh.updated)
        #expect(m.claude == .notInstalled)
        #expect(m.message?.contains("dev:") == true)
    }

    @Test func writesTheRawPathItRead() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        await m.refresh()
        var plan = try #require(await m.integrationPlan(.claude, install: true))
        // The path as read on the server wins over the URL's normalized one.
        let raw = h.home + "/raw dir/settings.json"
        plan.displayPath = "dev:" + raw
        plan.url = URL(fileURLWithPath: h.home + "/elsewhere/settings.json")
        #expect(await m.applyIntegration(plan))
        #expect(FileManager.default.fileExists(atPath: raw))
        #expect(!FileManager.default.fileExists(atPath: h.home + "/elsewhere/settings.json"))
    }

    @Test func symlinkedFileBacksUpNextToTarget() async throws {
        let h = try await Harness(); defer { h.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(atPath: h.home + "/dotfiles", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: h.home + "/.claude", withIntermediateDirectories: true)
        try "{}\n".write(toFile: h.home + "/dotfiles/settings.json", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: h.home + "/.claude/settings.json", withDestinationPath: "../dotfiles/settings.json")
        #expect(await h.remote.connect("dev") == .connected)
        let m = ServerCheckModel(host: "dev", remote: h.remote) { _, _ in RunResult(status: 0, stdout: "", stderr: "") }
        await m.refresh()
        let plan = try #require(await m.integrationPlan(.claude, install: true))
        #expect(plan.displayPath == "dev:" + h.home + "/.claude/settings.json")
        #expect(plan.backupDisplayPath == "dev:" + h.home + "/.claude/../dotfiles/settings.json")
        #expect(await m.applyIntegration(plan))
        #expect(try fm.contentsOfDirectory(atPath: h.home + "/dotfiles").contains { $0.hasPrefix("settings.json.hangar-backup-") })
        let type = try fm.attributesOfItem(atPath: h.home + "/.claude/settings.json")[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
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
