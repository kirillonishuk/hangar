import Foundation
import Testing
@testable import Workspace

@Suite struct ConfigTests {
    @Test func defaultsWhenEmpty() throws {
        let c = try HangarConfig.parse("")
        #expect(c == HangarConfig())
        #expect(c.defaultAgent == .claude)
        #expect(c.editor == "hx")
        #expect(c.agentCommands == [.claude: "claude", .codex: "codex"])
    }

    @Test func parsesSubset() throws {
        let c = try HangarConfig.parse("""
        # comment
        default_agent = "codex"

        editor = "nvim"   # trailing comment
        [agents]
        claude = "claude --model opus"
        """)
        #expect(c.defaultAgent == .codex)
        #expect(c.editor == "nvim")
        #expect(c.agentCommands[.claude] == "claude --model opus")
        #expect(c.agentCommands[.codex] == "codex")
    }

    @Test func rejectsUnknownAgent() {
        #expect(throws: (any Error).self) { try HangarConfig.parse(#"default_agent = "gpt""#) }
    }

    @Test func missingFileGivesDefaults() {
        let c = HangarConfig.load(from: URL(fileURLWithPath: "/nonexistent/hangar/config.toml"))
        #expect(c == HangarConfig())
    }
}
