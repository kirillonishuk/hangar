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

    @Test func missingFileNoWarning() {
        let r = HangarConfig.load(from: URL(fileURLWithPath: "/nonexistent/hangar/config.toml"))
        #expect(r.config == HangarConfig())
        #expect(r.warning == nil)
    }

    @Test func invalidFileYieldsWarning() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hangar-\(UUID()).toml")
        try "editor = hx\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = HangarConfig.load(from: url)
        #expect(r.config == HangarConfig())
        #expect(r.warning?.contains("line 1") == true)
        #expect(r.warning?.contains(url.lastPathComponent) == true)
    }

    @Test func parseErrorsCarryLines() {
        #expect(throws: HangarConfig.ParseError.syntax(line: 2, reason: "unterminated string")) {
            try HangarConfig.parse("editor = \"hx\"\neditor = \"nv")
        }
        #expect(throws: (any Error).self) { try HangarConfig.parse("[agents]\nfoo = \"x\"") }
        #expect("\(HangarConfig.ParseError.syntax(line: 3, reason: "x"))".isEmpty == false)
        #expect(HangarConfig.ParseError.syntax(line: 3, reason: "x").description.contains("line 3"))
    }
}
