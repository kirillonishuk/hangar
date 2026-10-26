import Exec
import Foundation
import Integration
import Testing
import ControlServer
import Workspace
@testable import HangarUI

/// The app's checks of `hangar doctor` (#61), from the values they read.
@MainActor @Suite struct DoctorChecksTests {
    @Test func toolProbeSkipsNoise() {
        let out = "motd line\nHANGAR-DOCTOR\tclaude\t/opt/bin/claude\t2.1.3 (Claude Code)\nHANGAR-DOCTOR\tbad\nHANGAR-DOCTOR\tcodex\t/opt/codex\t\n"
        let found = parseToolProbe(out)
        #expect(found["claude"]?.path == "/opt/bin/claude" && found["claude"]?.version == "2.1.3 (Claude Code)")
        #expect(found["codex"]?.version == "" && found["bad"] == nil && found.count == 2)
    }

    @Test func toolLevels() {
        #expect(toolCheck("claude", "claude", ("/b/claude", "2.1"), missing: .fail) == DoctorCheck(name: "claude", level: .ok, detail: "/b/claude  2.1"))
        #expect(toolCheck("claude", "claude", nil, missing: .fail).level == .fail)
        let codex = toolCheck("codex", "codex", nil, missing: .warn)
        #expect(codex.level == .warn && codex.fix?.contains("[agents]") == true)
    }

    @Test func hookLevels() {
        let url = URL(fileURLWithPath: "/tmp/settings.json")
        #expect(hookCheck("claude hooks", .installed, file: url).level == .ok)
        for state in [IntegrationState.notInstalled, .outdated, .installedStatuslineByUser] {
            let c = hookCheck("claude hooks", state, file: url)
            #expect(c.level == .warn && c.fix != nil, "\(state)")
        }
    }

    @Test func hostLevels() {
        #expect(hostCheck("dev", nil).level == .warn)
        var info = HostInfo()
        info.state = .unreachable("Permission denied")
        #expect(hostCheck("dev", info).level == .fail)
        info.state = .connected
        info.forwarding = true
        let text = "HANGAR home /home/u\nHANGAR tool git /usr/bin/git 2.43\nHANGAR tool tmux /usr/bin/tmux 3.4\nHANGAR client socat\n"
        info.report = parseServerReport(text + "HANGAR remote \(hangarRemoteVersion)\nHANGAR end\n")
        #expect(hostCheck("dev", info) == DoctorCheck(name: "ssh dev", level: .ok, detail: "connected, tmux 3.4, hangar-remote \(hangarRemoteVersion)"))
        info.report = parseServerReport(text.replacingOccurrences(of: "HANGAR tool tmux /usr/bin/tmux 3.4\n", with: "") + "HANGAR end\n")
        let c = hostCheck("dev", info)
        #expect(c.level == .warn && c.detail.contains("tmux missing") && c.detail.contains("hangar-remote missing"))
    }

    @Test func diskAndKeepAwake() {
        #expect(diskCheck(free: 500_000_000, path: "~/x").level == .fail)
        #expect(diskCheck(free: 3_000_000_000, path: "~/x").level == .warn)
        #expect(diskCheck(free: 50_000_000_000, path: "~/x") == DoctorCheck(name: "disk", level: .ok, detail: "50.0 GB free on ~/x"))
        #expect(keepAwakeCheck(enabled: true, held: true, working: 2).detail == "on, holding sleep off (2 working)")
        #expect(keepAwakeCheck(enabled: false, held: false, working: 0).detail == "off (Settings)")
    }

    /// The whole app answer with fake agents and temp integration files (never the user's ~/.claude).
    @Test func appAnswer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-doctor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = HangarConfig()
        config.agentCommands = [.claude: "true", .codex: "hangar-no-such-agent"]
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: dir), config: config,
                           configURL: dir.appendingPathComponent("config.toml"), socketPath: dir.path + "/hangar.sock")
        app.keepAwake = .inert()
        app.findAgentDirs = nil
        app.claudeSettingsURL = dir.appendingPathComponent("settings.json")
        let r = await app.doctorResult()
        let byName = Dictionary(r.checks.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["claude"]?.level == .ok)
        #expect(byName["codex"]?.level == .warn && byName["codex hooks"] == nil)
        #expect(byName["claude hooks"]?.detail.contains("not installed") == true)
        #expect(byName["keep-awake"] != nil && byName["disk"] != nil && byName["ghostty"] != nil)
    }

    @Test func ghosttyResources() throws {
        #expect(ghosttyCheck(resources: nil, bundled: false).level == .warn)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-doctor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ghostty"), withIntermediateDirectories: true)
        #expect(ghosttyCheck(resources: dir, bundled: true).level == .fail)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("terminfo"), withIntermediateDirectories: true)
        #expect(ghosttyCheck(resources: dir, bundled: true).level == .ok)
    }
}
