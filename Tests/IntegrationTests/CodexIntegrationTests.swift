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
    let x = "notify = [\n  \"python3\",\n  '/u/n.py', # c\n]\nmodel = \"o3\"\n"
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
