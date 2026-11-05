import Foundation
import Testing
import AgentStatus
@testable import ControlServer

/// Subagent fields of hook payloads (spec agent-subagents §3): read at `hangar event`, checked again at the socket.
@Suite struct SubagentPayloadTests {
    let tab = UUID(), leaf = UUID()

    private func event(_ kind: String, _ json: String) -> EventMessage? {
        eventMessage(kind: kind, tab: tab, leaf: leaf, args: [], payload: Data(json.utf8))
    }

    @Test func preToolUseOfTheAgentToolCarriesTheRow() {
        let m = event("subagent-start", #"""
        {"session_id":"s1","tool_name":"Agent","tool_use_id":"toolu_01ABC","tool_input":{"description":"Implement Task 2.2\nmore",
         "subagent_type":"Explore","prompt":"Find all API endpoints"}}
        """#)
        #expect(m?.toolUseId == "toolu_01ABC" && m?.agentType == "Explore" && m?.title == "Implement Task 2.2")
        #expect(m?.message == "Find all API endpoints")
        let long = event("subagent-start", #"{"tool_use_id":"t","tool_input":{"prompt":"\#(String(repeating: "x", count: 5000))"}}"#)
        #expect(long?.message?.count == 2000)
    }

    @Test func postToolUseOnlyOfTheAgentToolLinks() {
        let agent = event("tool", #"{"tool_name":"Agent","tool_use_id":"toolu_1","tool_response":{"status":"async_launched","agentId":"a4d2c8f1"}}"#)
        #expect(agent?.tool == "Agent" && agent?.toolUseId == "toolu_1" && agent?.agentId == "a4d2c8f1" && agent?.backgrounded == true)
        let done = event("tool", #"{"tool_name":"Task","tool_use_id":"toolu_2","tool_response":{"status":"completed","agentId":"b1"}}"#)
        #expect(done?.backgrounded == false && done?.agentId == "b1")
        let bash = event("tool", #"{"tool_name":"Bash","tool_use_id":"toolu_3","tool_response":{"agentId":"x"}}"#)
        #expect(bash?.tool == nil && bash?.toolUseId == nil && bash?.agentId == nil)
    }

    /// HD-145: `agent_id` on any other event means it fired inside a subagent.
    @Test func eventsInsideASubagentAreMarked() {
        #expect(event("tool", #"{"tool_name":"Bash","agent_id":"a1","agent_type":"Explore"}"#)?.inSubagent == true)
        #expect(event("subagent-start", #"{"tool_use_id":"t","agent_id":"a1"}"#)?.inSubagent == true)
        #expect(event("tool", #"{"tool_name":"Bash"}"#)?.inSubagent == nil)
        #expect(event("tool", #"{"tool_name":"Bash","agent_id":"../x"}"#)?.inSubagent == nil)
        #expect(event("subagent-stop", #"{"agent_id":"a1"}"#)?.inSubagent == nil)
        #expect(event("subagent-run", #"{"agent_id":"a1"}"#)?.inSubagent == nil)
    }

    @Test func subagentStartAndStopCarryTheAgentId() {
        let run = event("subagent-run", #"{"agent_id":"agent-abc123","agent_type":"my-plugin:reviewer"}"#)
        #expect(run?.kind == .subagentRun && run?.agentId == "agent-abc123" && run?.agentType == "my-plugin:reviewer")
        let stop = event("subagent-stop", #"{"agent_id":"def456","agent_type":"","last_assistant_message":"Found 3 issues"}"#)
        #expect(stop?.agentId == "def456" && stop?.agentType == nil && stop?.message == "Found 3 issues")
    }

    @Test func hostileIdsAndTypesAreDropped() {
        let m = event("subagent-run", #"{"agent_id":"../../etc/passwd","agent_type":"a\u0007b"}"#)
        #expect(m?.agentId == nil && m?.agentType == nil)
        #expect(subagentId(String(repeating: "a", count: 129)) == nil)
        #expect(subagentId("") == nil && subagentId("a b") == nil && subagentId("abc_DEF-09") == "abc_DEF-09")
        #expect(subagentType(String(repeating: "t", count: 65)) == nil)
        #expect(subagentTitle("  \n") == nil && subagentTitle("a\u{1B}[31mb") == "a[31mb")
        #expect(subagentTitle(String(repeating: "й", count: 300))?.count == 200)
    }

    @Test func theSocketChecksTheFieldsAgain() throws {
        let line = Data(#"""
        {"v":1,"type":"event","tab":"\#(tab.uuidString)","leaf":"\#(leaf.uuidString)","kind":"subagent-start","toolUseId":"../x",
         "agentId":"ok_1","agentType":"\#(String(repeating: "t", count: 70))","title":"one\ntwo","backgrounded":true}
        """#.utf8)
        guard case .success(.event(let m)) = ControlMessage.decode(line) else { Issue.record("not decoded"); return }
        #expect(m.toolUseId == nil && m.agentId == "ok_1" && m.agentType == nil && m.title == "one" && m.backgrounded == true)
    }
}
