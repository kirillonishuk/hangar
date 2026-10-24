import Foundation
import Testing
import ControlServer

/// `hangar://` links (#NN-links): the only shapes the app acts on, everything else is ignored.
@Suite struct LinksTests {
    private let id = "0f3a9c1e-1111-4222-8333-444455556666"

    @Test func generatesLowercasedURLs() {
        #expect(HangarLink(kind: .task, ref: id.uppercased()).url.absoluteString == "hangar://task/\(id)")
        #expect(HangarLink(kind: .tab, ref: id).url.absoluteString == "hangar://tab/\(id)")
        #expect(HangarLink(kind: .project, ref: id).url.absoluteString == "hangar://project/\(id)")
    }

    @Test func parsesWhatItGenerates() {
        for kind in LinkKind.allCases {
            let link = HangarLink(kind: kind, ref: id)
            #expect(HangarLink(url: link.url) == link)
        }
    }

    @Test func parsesPrefixesCaseAndTrailingSlash() {
        #expect(HangarLink(url: URL(string: "hangar://task/0F3A")!) == HangarLink(kind: .task, ref: "0f3a"))
        #expect(HangarLink(url: URL(string: "HANGAR://Task/0f3a9c1e/")!) == HangarLink(kind: .task, ref: "0f3a9c1e"))
    }

    @Test func rejectsEverythingElse() {
        let bad = [
            "hangar://task/", "hangar://task", "hangar://task/0f3", "hangar://task/zzzz", "hangar://task/0f3a/extra",
            "hangar://pane/0f3a9c1e", "hangar://task/0f3a9c1e?run=rm", "hangar://task/0f3a9c1e#x", "hangar://u@task/0f3a9c1e",
            "hangar://task:1/0f3a9c1e", "pane://task/0f3a9c1e", "https://task/0f3a9c1e", "hangar:task/0f3a9c1e",
            "hangar://task/\(id)0", "hangar://task/0f3a%2F..",
        ]
        for s in bad {
            let url = URL(string: s)
            #expect(url.flatMap(HangarLink.init(url:)) == nil, "\(s)")
        }
    }

    @Test func cliPrintsLinks() {
        #expect(parseCLI(["link", "task", "0f3a"], cwd: "/") == .call(.linksCreate(kind: .task, ref: "0f3a"), json: false))
        #expect(parseCLI(["link", "tab", "ab12", "--json"], cwd: "/") == .call(.linksCreate(kind: .tab, ref: "ab12"), json: true))
        #expect(parseCLI(["link", "project", "app"], cwd: "/") == .call(.linksCreate(kind: .project, ref: "app"), json: false))
        if case .usage = parseCLI(["link", "task"], cwd: "/") {} else { Issue.record("missing ref accepted") }
        if case .usage = parseCLI(["link", "pane", "x"], cwd: "/") {} else { Issue.record("unknown kind accepted") }
        let url = "hangar://task/\(id)"
        #expect(formatHuman(.linksCreate(kind: .task, ref: "0f3a"), result: Data(#"{"url":"\#(url)"}"#.utf8)) == url)
    }

    @Test func wireRoundTrip() {
        let call = ControlCall.linksCreate(kind: .tab, ref: "ab12")
        let params = (try? JSONSerialization.jsonObject(with: call.paramsJSON())) as? [String: Any] ?? [:]
        #expect(call.method.toolName == "links_create")
        #expect(ControlCall.decode(method: "links.create", params: params) == .success(call))
        guard case .failure(let e) = ControlCall.decode(method: "links.create", params: ["kind": "pane", "ref": "x"]) else {
            Issue.record("unknown kind accepted"); return
        }
        #expect(e.code == .badParams)
    }
}
