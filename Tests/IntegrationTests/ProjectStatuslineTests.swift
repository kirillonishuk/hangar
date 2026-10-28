import Foundation
import Testing
@testable import Integration

private let cli = "/Applications/Hangar.app/Contents/Helpers/hangar"
private let shared = """
{
  "permissions": {"allow": ["Bash(npm test)"]},
  "statusLine": {"type": "command", "command": "~/bin/line.sh --short", "padding": 1}
}
"""

private func statusLine(_ text: String?) -> String? {
    guard let text, case .object(let root) = try? parseJSON(text),
          case .object(let sl)? = root.first(where: { $0.key == "statusLine" })?.value,
          case .string(let c)? = sl.first(where: { $0.key == "command" })?.value else { return nil }
    return c
}

@Suite struct ProjectStatuslineTests {
    @Test func addsOverrideAndTakesItBack() throws {
        let local = #"{"permissions": {"allow": ["Bash(ls)"]}, "env": {"A": "1"}}"#
        let added = try #require(try projectStatuslineApply(shared: shared, local: local, cli: cli))
        #expect(statusLine(added) == "\(cli) statusline --project --then '~/bin/line.sh --short'")
        #expect(added.contains(#""padding": 1"#) && added.contains("Bash(ls)") && added.contains(#""A": "1""#))
        #expect(projectHasHangarStatusline(added))
        // Idempotent.
        #expect(try projectStatuslineApply(shared: shared, local: added, cli: cli) == nil)
        // Reverting removes exactly the added key; the user's keys stay in their order.
        let reverted = try #require(try projectStatuslineRevert(local: added))
        #expect(try parseJSON(reverted) == parseJSON(local))
        #expect(try projectStatuslineRevert(local: reverted) == nil)
    }

    @Test func noLocalFileYet() throws {
        let added = try #require(try projectStatuslineApply(shared: shared, local: nil, cli: cli))
        #expect(statusLine(added)?.hasSuffix("--then '~/bin/line.sh --short'") == true)
        #expect(try projectStatuslineRevert(local: added) == "{}\n")
    }

    @Test func nothingWithoutAProjectLine() throws {
        #expect(try projectStatuslineApply(shared: nil, local: nil, cli: cli) == nil)
        #expect(try projectStatuslineApply(shared: #"{"model": "opus"}"#, local: nil, cli: cli) == nil)
        #expect(try projectStatuslineApply(shared: "{ broken", local: nil, cli: cli) == nil)
        // A project that already runs Hangar's command needs nothing.
        #expect(try projectStatuslineApply(shared: #"{"statusLine": {"type": "command", "command": "hangar statusline"}}"#, local: nil, cli: cli) == nil)
    }

    @Test func wrapsAndRestoresAUsersLocalLine() throws {
        let local = #"{"statusLine": {"type": "command", "command": "echo mine"}}"#
        let wrapped = try #require(try projectStatuslineApply(shared: shared, local: local, cli: cli))
        #expect(statusLine(wrapped) == "\(cli) statusline --then 'echo mine'")
        #expect(try projectStatuslineApply(shared: shared, local: wrapped, cli: cli) == nil)
        let restored = try #require(try projectStatuslineRevert(local: wrapped))
        #expect(statusLine(restored) == "echo mine")
    }

    @Test func followsTheSharedLineAndTheCLI() throws {
        let added = try #require(try projectStatuslineApply(shared: shared, local: nil, cli: cli))
        let changed = shared.replacingOccurrences(of: "~/bin/line.sh --short", with: "other.sh")
        #expect(statusLine(try projectStatuslineApply(shared: changed, local: added, cli: cli)) == "\(cli) statusline --project --then other.sh")
        // The project dropped its line: Hangar's added key goes too.
        #expect(try projectStatuslineApply(shared: #"{"model": "opus"}"#, local: added, cli: cli) == "{}\n")
        let moved = try #require(try projectStatuslineApply(shared: shared, local: added, cli: "/opt/Hangar.app/Contents/Helpers/hangar"))
        #expect(statusLine(moved)?.hasPrefix("/opt/Hangar.app/Contents/Helpers/hangar statusline --project") == true)
    }

    @Test func leavesUnsupportedShapesAlone() throws {
        #expect(try projectStatuslineApply(shared: shared, local: #"{"statusLine": "text"}"#, cli: cli) == nil)
        #expect(throws: IntegrationError.self) { try projectStatuslineApply(shared: shared, local: "[1]", cli: cli) }
        #expect(throws: IntegrationError.self) { try projectStatuslineApply(shared: shared, local: "{ nope", cli: cli) }
        #expect(try projectStatuslineRevert(local: #"{"statusLine": {"command": "echo mine"}}"#) == nil)
    }

    @Test func userSettingsQueries() {
        let installed = #"{"statusLine": {"type": "command", "command": "'\#(cli)' statusline --then 'echo own'"}}"#
        #expect(hangarStatuslineCLI(installed) == cli)
        #expect(userStatuslineCommand(installed) == "echo own")
        #expect(hangarStatuslineCLI(#"{"statusLine": {"command": "echo own"}}"#) == nil)
        #expect(userStatuslineCommand(#"{"statusLine": {"command": "echo own"}}"#) == "echo own")
        #expect(userStatuslineCommand(#"{"statusLine": {"command": "'\#(cli)' statusline"}}"#) == nil)
        #expect(hangarStatuslineCLI(nil) == nil && userStatuslineCommand("{ x") == nil)
    }
}
