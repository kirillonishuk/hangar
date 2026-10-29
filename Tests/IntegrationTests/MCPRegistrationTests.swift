import Foundation
import Testing
@testable import Integration

private let cli = "/Applications/Hangar.app/Contents/Helpers/hangar"
private let old = "/Users/me/Downloads/Hangar.app/Contents/Helpers/hangar"
private let ours = localOwnership(cli: cli, exists: { _ in true })

private func claudeJSON(_ hangar: String) -> String {
    #"{"numStartups": 3, "projects": {"/x": {"mcpServers": {}}}, "mcpServers": {"other": {"command": "x"}, "hangar": \#(hangar)}}"#
}

@Suite struct MCPEntryTests {
    @Test func claudeEntries() {
        #expect(claudeMCPEntry(nil, cli: cli, ours: ours) == .absent)
        #expect(claudeMCPEntry(#"{"numStartups": 1}"#, cli: cli, ours: ours) == .absent)
        #expect(claudeMCPEntry(#"{"mcpServers": {"x": {}}}"#, cli: cli, ours: ours) == .absent)
        #expect(claudeMCPEntry(claudeJSON(#"{"type": "stdio", "command": "\#(cli)", "args": ["mcp"], "env": {}}"#), cli: cli, ours: ours) == .current)
        #expect(claudeMCPEntry(claudeJSON(#"{"command": "\#(old)", "args": ["mcp"]}"#), cli: cli, ours: ours) == .stale)
        // Someone else's server under the name, or ours with extra env / args: never touched.
        #expect(claudeMCPEntry(claudeJSON(#"{"command": "npx", "args": ["hangar-mcp"]}"#), cli: cli, ours: ours) == .foreign)
        #expect(claudeMCPEntry(claudeJSON(#"{"command": "\#(cli)", "args": ["mcp"], "env": {"A": "1"}}"#), cli: cli, ours: ours) == .foreign)
        #expect(claudeMCPEntry(claudeJSON(#"{"type": "http", "url": "http://x"}"#), cli: cli, ours: ours) == .foreign)
        #expect(claudeMCPEntry("{nope", cli: cli, ours: ours) == .unreadable)
    }

    @Test func otherCopyIsLeftAlone() {
        // This copy runs from Downloads; the entry leads into an existing /Applications copy.
        let mine = "/Users/me/Downloads/Hangar.app/Contents/Helpers/hangar"
        let o = localOwnership(cli: mine, exists: { $0 == cli })
        #expect(claudeMCPEntry(claudeJSON(#"{"command": "\#(cli)", "args": ["mcp"]}"#), cli: mine, ours: o) == .otherCopy)
        // The /Applications copy is gone: the entry is a stale one of ours.
        let gone = localOwnership(cli: mine, exists: { _ in false })
        #expect(claudeMCPEntry(claudeJSON(#"{"command": "\#(cli)", "args": ["mcp"]}"#), cli: mine, ours: gone) == .stale)
    }

    @Test func codexEntries() {
        #expect(codexMCPEntry(nil, cli: cli, ours: ours) == .absent)
        #expect(codexMCPEntry("model = \"o3\"\n[mcp_servers.other]\ncommand = \"x\"\n", cli: cli, ours: ours) == .absent)
        let table = "model = \"o3\"\n\n[mcp_servers.hangar]\ncommand = \"\(cli)\"\nargs = [\"mcp\"]\n\n[tui]\nx = 1\n"
        #expect(codexMCPEntry(table, cli: cli, ours: ours) == .current)
        #expect(codexMCPEntry(table.replacingOccurrences(of: cli, with: old), cli: cli, ours: ours) == .stale)
        let inline = "[mcp_servers]\nhangar = { command = '\(old)', args = [\"mcp\"] }\n"
        #expect(codexMCPEntry(inline, cli: cli, ours: ours) == .stale)
        let quoted = "[mcp_servers.\"hangar\"]\ncommand = \"\(cli)\"\nargs = [\n  \"mcp\",\n]\n"
        #expect(codexMCPEntry(quoted, cli: cli, ours: ours) == .current)
        let env = table + "[mcp_servers.hangar.env]\nTOKEN = \"x\"\n"
        #expect(codexMCPEntry(env, cli: cli, ours: ours) == .foreign)
        #expect(codexMCPEntry("[mcp_servers.hangar]\ncommand = \"npx\"\nargs = [\"-y\", \"hangar\"]\n", cli: cli, ours: ours) == .foreign)
        // A multi-line string elsewhere does not confuse the scan.
        let multi = "notes = \"\"\"\n[mcp_servers.hangar]\ncommand = \"evil\"\n\"\"\"\n" + table
        #expect(codexMCPEntry(multi, cli: cli, ours: ours) == .current)
        #expect(codexMCPEntry("[mcp_servers.hangar\n", cli: cli, ours: ours) == .unreadable)
    }

    @Test func actions() {
        #expect(mcpAction(.absent, enabled: true) == .add)
        #expect(mcpAction(.stale, enabled: true) == .readd)
        for e in [MCPEntry.current, .otherCopy, .foreign, .unreadable] { #expect(mcpAction(e, enabled: true) == .none) }
        #expect(mcpAction(.current, enabled: false) == .remove)
        #expect(mcpAction(.stale, enabled: false) == .remove)
        for e in [MCPEntry.absent, .otherCopy, .foreign, .unreadable] { #expect(mcpAction(e, enabled: false) == .none) }
    }

    @Test func commands() {
        #expect(mcpCommands(.claude, .add, agentCLI: "/b/claude", cli: cli) == [["/b/claude", "mcp", "add", "--scope", "user", "hangar", "--", cli, "mcp"]])
        #expect(mcpCommands(.claude, .readd, agentCLI: "/b/claude", cli: cli) == [
            ["/b/claude", "mcp", "remove", "--scope", "user", "hangar"],
            ["/b/claude", "mcp", "add", "--scope", "user", "hangar", "--", cli, "mcp"],
        ])
        #expect(mcpCommands(.codex, .readd, agentCLI: "/b/codex", cli: cli) == [["/b/codex", "mcp", "add", "hangar", "--", cli, "mcp"]])
        #expect(mcpCommands(.codex, .remove, agentCLI: "/b/codex", cli: cli) == [["/b/codex", "mcp", "remove", "hangar"]])
        #expect(mcpCommands(.claude, .none, agentCLI: "/b/claude", cli: cli).isEmpty)
    }

    @Test func claudeJSONFollowsConfigDir() {
        let home = URL(fileURLWithPath: "/h")
        #expect(claudeJSONPath(home: home, claudeConfigDir: nil).path == "/h/.claude.json")
        #expect(claudeJSONPath(home: home, claudeConfigDir: "/c").path == "/c/.claude.json")
        #expect(claudeJSONPath(home: home, claudeConfigDir: "rel").path == "/h/.claude.json")
    }
}
