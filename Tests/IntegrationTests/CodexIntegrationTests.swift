import Foundation
import Testing
@testable import Integration

// verify: проверить, когда codex будет установлен — формат notify и аргумент (JSON-payload последним argv) взяты из документации.

@Test func codexInstallWithoutNotify() throws {
    let x = "model = \"o3\"\n\n[profiles.x]\nnotify = [\"a\"]\n"
    let out = try codexInstall(x, cli: "/A/hangar")
    #expect(out == "model = \"o3\"\nnotify = [\"/A/hangar\", \"event\", \"codex-notify\"]\n\n[profiles.x]\nnotify = [\"a\"]\n")
    #expect(try tomlRootStringArray(out, key: "notify")?.values == ["/A/hangar", "event", "codex-notify"])
    // CRLF is kept
    let crlf = try codexInstall("model = \"o3\"\r\n[t]\r\n", cli: "/A/hangar")
    #expect(crlf == "model = \"o3\"\r\nnotify = [\"/A/hangar\", \"event\", \"codex-notify\"]\r\n[t]\r\n")
    #expect(try codexInstall(nil, cli: "/A/hangar") == "notify = [\"/A/hangar\", \"event\", \"codex-notify\"]\n")
}

@Test func codexChainsExistingMultilineNotify() throws {
    let x = "notify = [\n  \"python3\",\n  '/u/n.py',\n]\nmodel = \"o3\"\n"
    let out = try codexInstall(x, cli: "/A/hangar")
    #expect(out == "notify = [\"/A/hangar\", \"event\", \"codex-notify\", \"--then\", \"python3\", \"/u/n.py\"]\nmodel = \"o3\"\n")
    let back = try codexUninstall(out)
    #expect(back == "notify = [\"python3\", \"/u/n.py\"]\nmodel = \"o3\"\n")
    #expect(try tomlRootStringArray(back, key: "notify")?.values == ["python3", "/u/n.py"])
}

@Test func codexUninstallRoundTripWithoutNotify() throws {
    for x in ["", "model = \"o3\"\n\n[profiles.x]\nnotify = [\"a\"]\n", "# c\nmodel = 1\n", "[t]\na = 1\n"] {
        #expect(try codexUninstall(codexInstall(x, cli: "/A/hangar")) == x)
    }
}

@Test func codexIdempotentAndMovedApp() throws {
    let x = "notify = [\"python3\", \"n.py\"]\n"
    #expect(codexState(x, cli: "/A/hangar") == .notInstalled)
    #expect(codexState(nil, cli: "/A/hangar") == .notInstalled)
    let a = try codexInstall(x, cli: "/A/hangar")
    #expect(codexState(a, cli: "/A/hangar") == .installed)
    #expect(try codexInstall(a, cli: "/A/hangar") == a)
    #expect(codexState(a, cli: "/B/hangar") == .outdated)
    let b = try codexInstall(a, cli: "/B/hangar")
    #expect(b == "notify = [\"/B/hangar\", \"event\", \"codex-notify\", \"--then\", \"python3\", \"n.py\"]\n")
    #expect(try codexUninstall(b) == "notify = [\"python3\", \"n.py\"]\n")
}

@Test func codexRejectsUnsupported() {
    #expect(throws: IntegrationError.unsupportedNotify) { try codexInstall("notify = \"x\"\n", cli: "/A/hangar") }
    #expect(throws: IntegrationError.unsupportedNotify) { try codexInstall("notify = [1]\n", cli: "/A/hangar") }
    #expect(throws: IntegrationError.invalidTOML(line: 1)) { try codexInstall("notify = [\"a\"\n", cli: "/A/hangar") }
    #expect(throws: IntegrationError.invalidTOML(line: 2)) { try tomlRootStringArray("a = 1\nnotify = [\"a\n]", key: "notify") }
}

@Test func tomlStringsAndScope() throws {
    let x = "a = '''\n[x]\nnotify = [\"no\"]\n'''\nnotify = [\"q\\\"\\\\ \\u00e9\\t\", 'l\\i'] # tail\n[t]\nnotify = [\"z\"]\n"
    let r = try #require(try tomlRootStringArray(x, key: "notify"))
    #expect(r.values == ["q\"\\ é\t", "l\\i"])
    #expect(r.lines == 4..<5)
    #expect(try tomlRootStringArray("[t]\nnotify = [\"z\"]\n", key: "notify") == nil)
    // quoting on write
    let out = try codexInstall("", cli: "/My \"App\"/hangar")
    #expect(try tomlRootStringArray(out, key: "notify")?.values.first == "/My \"App\"/hangar")
}

// Scanner robustness: whatever the file holds, either edit correctly or refuse; never a duplicate key or a lost root.

@Test func codexScannerSkipsNestedArraysAndMultilineStrings() throws {
    let cli = "/A/hangar"
    let arrays = "a = [\n  [1,2],\n  [3]\n]\nmodel = \"o\"\n[t]\nx = 1\n"
    let out1 = try codexInstall(arrays, cli: cli)
    #expect(out1 == "a = [\n  [1,2],\n  [3]\n]\nmodel = \"o\"\nnotify = [\"/A/hangar\", \"event\", \"codex-notify\"]\n[t]\nx = 1\n")
    #expect(try codexUninstall(out1) == arrays)

    let str = "a = \'\'\'\n[x]\nnotify = [\"no\"]\n\'\'\'\nb = \"\"\"\n[y]\n\"\"\"\n"
    let out2 = try codexInstall(str, cli: cli)
    #expect(out2 == str + "notify = [\"/A/hangar\", \"event\", \"codex-notify\"]\n")
    #expect(try codexUninstall(out2) == str)

    let after = "a = [\n  [1,2],\n  [3]\n]\nnotify = [\"x\"]\n"
    let out3 = try codexInstall(after, cli: cli)
    #expect(out3 == "a = [\n  [1,2],\n  [3]\n]\nnotify = [\"/A/hangar\", \"event\", \"codex-notify\", \"--then\", \"x\"]\n")
    #expect(try codexUninstall(out3) == after)
    // inline tables and trailing array of tables header
    let inl = "a = { b = [1, 2], c = \"[\" }\n[[t]]\n"
    #expect(try codexInstall(inl, cli: cli) == "a = { b = [1, 2], c = \"[\" }\nnotify = [\"/A/hangar\", \"event\", \"codex-notify\"]\n[[t]]\n")
}

@Test func codexRefusesQuotedAndDottedNotifyKeys() {
    for x in ["\"notify\" = [\"a\"]\n", "'notify' = [\"a\"]\n", "notify.x = 1\n", "notify = [\"a\"]\nnotify = [\"b\"]\n"] {
        #expect(throws: IntegrationError.unsupportedNotify) { try codexInstall(x, cli: "/A/hangar") }
    }
    #expect(codexState("\"notify\" = [\"a\"]\n", cli: "/A/hangar") == .notInstalled)
}

@Test func codexKeepsTrailingCommentRefusesInnerComments() throws {
    let x = "notify = [\"a\"] # keep me\n"
    let out = try codexInstall(x, cli: "/A/hangar")
    #expect(out == "notify = [\"/A/hangar\", \"event\", \"codex-notify\", \"--then\", \"a\"] # keep me\n")
    #expect(try codexUninstall(out) == x)
    let multi = "notify = [\n  \"a\",\n] # tail\n"
    #expect(try codexUninstall(codexInstall(multi, cli: "/A/hangar")) == "notify = [\"a\"] # tail\n")
    #expect(throws: IntegrationError.unsupportedNotify) { try codexInstall("notify = [\n  \"a\", # c\n  \"b\"\n]\n", cli: "/A/hangar") }
    #expect(throws: IntegrationError.unsupportedNotify) { try codexInstall("notify = [ # c\n \"a\"]\n", cli: "/A/hangar") }
}

@Test func codexChainedValuesRoundTrip() throws {
    let x = "notify = [\"a b\", \"q\\\"x\\\\\", 'C:\\p q', \"\\u00e9\\t\"]\n"
    let orig = try #require(try tomlRootStringArray(x, key: "notify")).values
    let out = try codexInstall(x, cli: "/My App/\"h\"/hangar")
    #expect(try tomlRootStringArray(out, key: "notify")?.values == ["/My App/\"h\"/hangar", "event", "codex-notify", "--then"] + orig)
    #expect(try tomlRootStringArray(codexUninstall(out), key: "notify")?.values == orig)
}
