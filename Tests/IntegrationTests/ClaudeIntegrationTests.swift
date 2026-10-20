import Foundation
import Testing
import Exec
@testable import Integration

private let fEmpty = "{}\n"
private let fHooks = #"""
{
  "model": "opus",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "say done"
          }
        ]
      }
    ]
  },
  "permissions": {
    "allow": [
      "Bash(ls:*)"
    ]
  }
}

"""#
private let fStatus = #"""
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/sl.sh 'a b'",
    "padding": 2
  }
}

"""#
private let fBoth = #"""
{
  "statusLine": {
    "type": "command",
    "command": "echo \"$HOME\" && date"
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "lint.sh"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "afplay /System/Library/Sounds/Ping.aiff"
          }
        ]
      }
    ]
  },
  "env": {
    "X": "1"
  }
}

"""#
private let fixtures = [fEmpty, fHooks, fStatus, fBoth]

private func obj(_ v: JSONValue) -> [JSONMember] { if case .object(let m) = v { return m }; return [] }
private func arr(_ v: JSONValue?) -> [JSONValue] { if case .array(let a)? = v { return a }; return [] }
private func str(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
private func get(_ v: JSONValue?, _ k: String) -> JSONValue? { v.flatMap { obj($0).first { $0.key == k }?.value } }
private func statusCommand(_ text: String) throws -> String? { str(get(get(try parseJSON(text), "statusLine"), "command")) }
/// All hook commands in file order, flattened.
private func commands(_ text: String) throws -> [String] {
    let hooks = get(try parseJSON(text), "hooks")
    return obj(hooks ?? .null).flatMap { ev in arr(ev.value).flatMap { g in arr(get(g, "hooks")).compactMap { str(get($0, "command")) } } }
}

@Test func installIntoEmpty() throws {
    let expected = #"""
    {
      "hooks": {
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/A/hangar event session-start",
                "timeout": 5
              }
            ]
          }
        ],
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/A/hangar event prompt",
                "timeout": 5
              }
            ]
          }
        ],
        "PostToolUse": [
          {
            "matcher": "*",
            "hooks": [
              {
                "type": "command",
                "command": "/A/hangar event tool",
                "timeout": 5
              }
            ]
          }
        ],
        "Notification": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/A/hangar event notification",
                "timeout": 5
              }
            ]
          }
        ],
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/A/hangar event stop",
                "timeout": 5
              }
            ]
          }
        ],
        "StopFailure": [
          {
            "matcher": "rate_limit",
            "hooks": [
              {
                "type": "command",
                "command": "/A/hangar event stop-failure",
                "timeout": 5
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "/A/hangar statusline"
      }
    }

    """#
    #expect(try claudeInstall(nil, cli: "/A/hangar") == expected)
    #expect(try claudeInstall("", cli: "/A/hangar") == expected)
    #expect(try claudeInstall(fEmpty, cli: "/A/hangar") == expected)
}

@Test func installPreservesUserHooksAndKeys() throws {
    let out = try claudeInstall(fHooks, cli: "/A/hangar")
    let root = try parseJSON(out)
    #expect(obj(root).map(\.key) == ["model", "hooks", "permissions", "statusLine"])
    #expect(get(root, "model") == .string("opus"))
    #expect(get(root, "permissions") == get(try parseJSON(fHooks), "permissions"))
    let hookKeys = obj(get(root, "hooks")!).map(\.key)
    #expect(hookKeys == ["Stop", "SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "StopFailure"])
    let stop = arr(get(get(root, "hooks"), "Stop"))
    #expect(stop.count == 2)
    #expect(str(get(arr(get(stop[0], "hooks"))[0], "command")) == "say done")
    #expect(str(get(arr(get(stop[1], "hooks"))[0], "command")) == "/A/hangar event stop")
}

@Test func installIsIdempotent() throws {
    for f in fixtures {
        let once = try claudeInstall(f, cli: "/A/hangar")
        #expect(try claudeInstall(once, cli: "/A/hangar") == once)
    }
}

@Test func installUpdatesMovedApp() throws {
    for f in fixtures {
        #expect(claudeState(f, cli: "/New/hangar") == .notInstalled)
        let old = try claudeInstall(f, cli: "/Old/hangar")
        #expect(claudeState(old, cli: "/Old/hangar") == .installed)
        #expect(claudeState(old, cli: "/New/hangar") == .outdated)
        let new = try claudeInstall(old, cli: "/New/hangar")
        #expect(!new.contains("/Old"))
        #expect(claudeState(new, cli: "/New/hangar") == .installed)
        let ours = try commands(new).filter(isHangarCommand)
        #expect(ours.count == claudeHooks.count)
        #expect(Set(ours).count == ours.count)
        // --then preserved through the move
        let original = try statusCommand(f)
        let words = shellWords(try statusCommand(new)!)!
        if let original {
            #expect(words == ["/New/hangar", "statusline", "--then", original])
        } else {
            #expect(words == ["/New/hangar", "statusline"])
        }
    }
    #expect(claudeState(nil, cli: "/New/hangar") == .notInstalled)
    #expect(claudeState("not json", cli: "/New/hangar") == .notInstalled)
}

@Test func partialInstallIsOutdated() throws {
    let full = try claudeInstall(nil, cli: "/A/hangar")
    let noStatus = try parseJSON(full)
    let trimmed = JSONValue.object(obj(noStatus).filter { $0.key != "statusLine" })
    #expect(claudeState(printJSON(trimmed), cli: "/A/hangar") == .outdated)
}

@Test func statuslineWrapped() throws {
    let out = try claudeInstall(fStatus, cli: "/A/hangar")
    let sl = get(try parseJSON(out), "statusLine")
    #expect(str(get(sl, "command")) == "/A/hangar statusline --then 'bash ~/.claude/sl.sh '\\''a b'\\'''")
    #expect(get(sl, "padding") == .number("2"))
    #expect(obj(sl!).map(\.key) == ["type", "command", "padding"])
}

@Test func uninstallRestores() throws {
    for f in fixtures {
        #expect(try claudeUninstall(claudeInstall(f, cli: "/A/hangar")) == f)
        #expect(try claudeUninstall(claudeInstall(f, cli: "/Users/me/My Apps/Hangar.app/Contents/Helpers/hangar")) == f)
    }
}

@Test func uninstallRemovesOnlyHangar() throws {
    let mixed = #"""
    {
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "say done"
              },
              {
                "type": "command",
                "command": "/A/hangar event stop",
                "timeout": 5
              }
            ]
          }
        ]
      }
    }

    """#
    let out = try claudeUninstall(mixed)
    #expect(try commands(out) == ["say done"])
    #expect(!out.contains("hangar"))
    // A user's own empty containers are not ours to delete.
    #expect(try claudeUninstall(#"{"hooks": {"Stop": []}}"#) == "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n")
}

@Test func pathWithSpaces() throws {
    let cli = "/Users/me/My Apps/Hangar.app/Contents/Helpers/hangar"
    let out = try claudeInstall(fBoth, cli: cli)
    let ours = try commands(out).filter(isHangarCommand)
    #expect(ours.count == claudeHooks.count)
    #expect(ours.allSatisfy { $0.hasPrefix("'/Users/me/My Apps/Hangar.app/Contents/Helpers/hangar' event ") })
    #expect(shellWords(ours[0])?.first == cli)
    let sl = try statusCommand(out)!
    #expect(isHangarCommand(sl))
    #expect(shellWords(sl) == [cli, "statusline", "--then", #"echo "$HOME" && date"#])
    #expect(claudeState(out, cli: cli) == .installed)
    let back = try claudeUninstall(out)
    #expect(!back.contains("hangar"))
    #expect(back == fBoth)
}

@Test func shellWordsAndHangarDetection() {
    #expect(shellWords(#"a 'b c' "d \"e\" \$f" g\ h"#) == ["a", "b c", #"d "e" $f"#, "g h"])
    #expect(shellWords("a 'b") == nil)
    #expect(shellWords(#"a "b"#) == nil)
    #expect(shellWords("  ") == [])
    #expect(isHangarCommand("hangar event stop"))
    #expect(isHangarCommand("/x/hangar statusline"))
    #expect(!isHangarCommand("/x/hangar-tool event stop"))
    #expect(!isHangarCommand("/x/hangar other"))
    #expect(!isHangarCommand("say hangar event"))
    #expect(!isHangarCommand("'unclosed"))
}

/// The wrapped statusline, run the way Claude runs it (`/bin/sh -c`), must hand `--then` the user's exact command.
@Test func thenArgumentRoundTripsThroughShell() throws {
    let dir = URL(fileURLWithPath: "/tmp/hg-\(UUID().uuidString.prefix(8))/My Apps")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let fake = dir.appendingPathComponent("hangar")
    try "#!/bin/sh\nprintf '%s' \"$3\"\n".write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let originals = [
        "bash ~/.claude/sl.sh 'a b'",
        #"echo "$HOME" && date"#,
        #"printf '%s\n' "it's" $PATH && echo 'x\y'"#,
        "a  b\ttab",
    ]
    for original in originals {
        let settings = printJSON(.object([JSONMember(key: "statusLine", value: .object([
            JSONMember(key: "type", value: .string("command")), JSONMember(key: "command", value: .string(original)),
        ]))]))
        let installed = try claudeInstall(settings, cli: fake.path)
        let cmd = try statusCommand(installed)!
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let got = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(got == original)
        #expect(try claudeUninstall(installed) == settings)
    }
}

@Test func lineDiffAndCollapse() {
    #expect(lineDiff("a\nb\nc\n", "a\nx\nc\n") == [.same("a"), .removed("b"), .added("x"), .same("c")])
    #expect(lineDiff("", "a\n") == [.added("a")])
    let pre = (1...20).map { "p\($0)" }, post = (1...20).map { "q\($0)" }
    let old = (pre + ["old"] + post).joined(separator: "\n") + "\n"
    let new = (pre + ["new"] + post).joined(separator: "\n") + "\n"
    let c = collapsed(lineDiff(old, new), context: 3)
    #expect(c == [.skipped(17), .same("p18"), .same("p19"), .same("p20"), .removed("old"), .added("new"),
                  .same("q1"), .same("q2"), .same("q3"), .skipped(17)])
    // Interior run keeps context on both sides; a short run is untouched.
    let mid = ["a"] + pre + ["b"]
    let d = collapsed(lineDiff(mid.joined(separator: "\n"), (["A"] + pre + ["B"]).joined(separator: "\n")), context: 3)
    #expect(d == [.removed("a"), .added("A"), .same("p1"), .same("p2"), .same("p3"), .skipped(14),
                  .same("p18"), .same("p19"), .same("p20"), .removed("b"), .added("B")])
    let short = lineDiff("a\nb\nc\n", "a\nb\nc\nd\n")
    #expect(collapsed(short, context: 3) == short)
}

@Test func statuslineNotOursIsDistinctState() throws {
    let full = try parseJSON(try claudeInstall(nil, cli: "/A/hangar"))
    func with(_ sl: JSONValue) -> String {
        printJSON(.object(obj(full).map { $0.key == "statusLine" ? JSONMember(key: "statusLine", value: sl) : $0 }))
    }
    #expect(claudeState(with(.string("x")), cli: "/A/hangar") == .installedStatuslineByUser)
    #expect(claudeState(with(.object([JSONMember(key: "type", value: .string("command"))])), cli: "/A/hangar") == .installedStatuslineByUser)
    // A user's plain command is wrapped by install, so before that it is still outdated.
    let plain = JSONValue.object([JSONMember(key: "command", value: .string("echo hi"))])
    #expect(claudeState(with(plain), cli: "/A/hangar") == .outdated)
}

@Test func lineDiffShowsTrailingNewlineChange() {
    let d = lineDiff("a\n", "a")
    #expect(d != [.same("a")] && d.contains { if case .added = $0 { true } else { false } })
    #expect(lineDiff("a", "a\n").contains { if case .removed = $0 { true } else { false } })
    #expect(lineDiff("a", "a") == [.same("a")])
}
