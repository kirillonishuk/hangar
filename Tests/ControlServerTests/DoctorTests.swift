import Foundation
import Testing
@testable import ControlServer

/// `hangar doctor` / MCP `doctor` (decision #NN-doctor): the CLI side of the report.
@Suite struct DoctorTests {
    private let agents = DoctorCheck(name: "claude", level: .ok, detail: "/usr/local/bin/claude 2.1.3")
    private let hooks = DoctorCheck(name: "claude hooks", level: .warn, detail: "not installed", fix: "Settings → Integrations → Install")

    @Test func appReachableSameVersion() {
        let r = doctorReport(app: .success(DoctorResult(appVersion: "1.2", checks: [agents])), cliVersion: "1.2")
        #expect(r.checks.map(\.name) == ["app", "version", "claude"])
        #expect(r.checks.prefix(2).allSatisfy { $0.level == .ok })
        #expect(r.exitCode == 0 && r.ok)
    }

    @Test func warnStillExitsZeroVersionMismatchWarns() {
        let r = doctorReport(app: .success(DoctorResult(appVersion: "1.3", checks: [hooks])), cliVersion: "1.2")
        #expect(r.checks[1].level == .warn && r.checks[1].fix != nil)
        #expect(r.exitCode == 0)
    }

    @Test func appDownFails() {
        let r = doctorReport(app: .failure(ControlError(code: .notRunning, message: "Hangar is not running")), cliVersion: "1.2")
        #expect(r.checks.first?.level == .fail && r.checks.first?.fix != nil)
        #expect(r.exitCode == 1 && !r.ok)
    }

    @Test func anyFailExitsOne() {
        let disk = DoctorCheck(name: "disk", level: .fail, detail: "120 MB free", fix: "Free disk space")
        #expect(doctorReport(app: .success(DoctorResult(appVersion: "1", checks: [agents, disk])), cliVersion: "1").exitCode == 1)
    }

    @Test func humanFormat() {
        let r = doctorReport(app: .success(DoctorResult(appVersion: "1.2", checks: [agents, hooks])), cliVersion: "1.2")
        let text = formatDoctor(r)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains("ok    claude        /usr/local/bin/claude 2.1.3"))
        #expect(lines.contains("warn  claude hooks  not installed"))
        #expect(lines.contains("                    fix: Settings → Integrations → Install"))
        #expect(lines.last == "1 warning, no failures")
    }

    @Test func jsonRoundTrips() throws {
        let r = doctorReport(app: .success(DoctorResult(appVersion: "1.2", checks: [hooks])), cliVersion: "1.2")
        let object = try #require(try JSONSerialization.jsonObject(with: doctorJSON(r)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        let checks = try #require(object["checks"] as? [[String: Any]])
        #expect(checks.last?["level"] as? String == "warn" && checks.last?["fix"] as? String == hooks.fix)
        #expect(try JSONDecoder().decode(DoctorReport.self, from: doctorJSON(r)) == r)
    }

    @Test func parsesArgs() {
        #expect(parseDoctorArgs(["doctor"]) == .call(.doctor, json: false))
        #expect(parseDoctorArgs(["doctor", "--json"]) == .call(.doctor, json: true))
        #expect(parseDoctorArgs(["doctor", "--fix"]) == .usage("unknown flag \"--fix\""))
    }
}
