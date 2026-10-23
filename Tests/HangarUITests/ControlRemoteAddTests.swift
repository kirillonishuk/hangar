import ControlServer
import Exec
import Foundation
import Testing
@testable import HangarUI

/// `projects.add` with a host against the fake ssh only (never a real host); the harness is RemoteHostsTests'.
@MainActor @Suite struct ControlRemoteAddTests {
    private func respond(_ h: RemoteHostsTests.Harness, path: String, host: String) async -> Result<ProjectAddResult, ControlError> {
        switch await h.app.respond(7, .projectsAdd(path: path, host: host)).body {
        case .success(let data): (try? JSONDecoder().decode(ProjectAddResult.self, from: data)).map { .success($0) } ?? .failure(ControlError(code: .failed, message: "decode"))
        case .failure(let e): .failure(e)
        }
    }

    private func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    @Test func addsWithServerPath() async throws {
        let h = try await RemoteHostsTests.Harness(); defer { h.cleanup() }
        try await h.loginTools()
        try FileManager.default.createDirectory(atPath: h.home + "/proj", withIntermediateDirectories: true)
        let real = realPath(h.home + "/proj")

        guard case .success(let first) = await respond(h, path: "~/proj", host: "fresh") else { Issue.record("not added"); return }
        #expect(first.added && first.project.host == "fresh" && first.project.path == real && first.project.name == "proj")
        #expect(h.app.state.projects.contains { $0.id == first.project.id && $0.host == "fresh" && $0.path == real })
        // git and tmux are there: no tool warning (hangar-remote is not written yet).
        #expect(first.warnings?.contains { $0.hasPrefix("git ") || $0.hasPrefix("tmux ") } == false)
        #expect(first.warnings?.contains("hangar-remote missing or outdated on server; open Hangar → Server to install") == true)

        // Relative (from the server home) and absolute name the same folder.
        for path in ["proj", real] {
            guard case .success(let again) = await respond(h, path: path, host: "fresh") else { Issue.record("failed \(path)"); continue }
            #expect(!again.added && again.project.id == first.project.id)
        }
        #expect(h.app.state.projects.filter { $0.host == "fresh" }.count == 1)
    }

    @Test func missingToolsWarnNotBlock() async throws {
        let h = try await RemoteHostsTests.Harness(); defer { h.cleanup() }
        guard case .success(let r) = await respond(h, path: "~", host: "fresh") else { Issue.record("not added"); return }
        #expect(r.added)
        // The fake server's PATH is /usr/bin:/bin plus a test bin: tmux there depends on this Mac.
        if h.remote.hosts["fresh"]?.report?.tmux == false {
            #expect(r.warnings?.contains("tmux missing on server; open Hangar → Server to install") == true)
        }
        #expect(!FakeSSH.calls(h.log).contains { $0.joined(separator: " ").contains("install") })
    }

    @Test func errors() async throws {
        let h = try await RemoteHostsTests.Harness(); defer { h.cleanup() }
        func failure(_ path: String = "~", _ host: String = "fresh") async -> ControlError? {
            if case .failure(let e) = await respond(h, path: path, host: host) { return e }
            return nil
        }

        let missing = await failure("~/nope")
        #expect(missing == ControlError(code: .notFound, message: "folder not found on server"))
        #expect(h.remote.hosts["fresh"] == nil)  // released: no project uses it

        try h.flag("fail", "auth")
        #expect(await failure() == ControlError(code: .failed, message: "auth failed: run ssh fresh in Terminal, then retry"))
        #expect(h.remote.hosts["fresh"] == nil)
        try h.flag("fail", "refused")
        #expect(await failure() == ControlError(code: .failed, message: "host not connected"))
        try FileManager.default.removeItem(atPath: h.fakeDir + "/fail")

        try (h.bin + "/tcsh").write(toFile: h.root + "/shell", atomically: true, encoding: .utf8)
        #expect(await failure() == ControlError(code: .failed, message: "unsupported login shell (csh/tcsh)"))

        let before = FakeSSH.calls(h.log).count
        #expect(await failure("~", "-oProxyCommand=x")?.code == .badParams)
        #expect(FakeSSH.calls(h.log).count == before)
        #expect(h.app.state.projects.count == 3)
    }

    @Test func warningsFromReport() throws {
        let text = "HANGAR home /home/u\nHANGAR tool git /usr/bin/git 2.43\nHANGAR remote \(hangarRemoteVersion)\nHANGAR end\n"
        var info = HostInfo(state: .connected, home: "/home/u", report: parseServerReport(text), forwarding: true)
        #expect(remoteAddWarnings(info) == [
            "tmux missing on server; open Hangar → Server to install",
            "no socket client (python3, socat or nc) on server, agent statuses unavailable; open Hangar → Server to install",
        ])
        info.forwarding = false
        info.report = parseServerReport(text.replacingOccurrences(of: "HANGAR remote \(hangarRemoteVersion)\n", with: "HANGAR client nc\nHANGAR tool tmux /usr/bin/tmux 3.4\n"))
        #expect(remoteAddWarnings(info) == [
            "hangar-remote missing or outdated on server; open Hangar → Server to install",
            "socket forwarding refused by server, agent statuses unavailable",
        ])
    }
}
