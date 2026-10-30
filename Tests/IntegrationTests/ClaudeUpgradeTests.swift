import Foundation
import Testing
@testable import Integration

/// A settings file installed before decision #96: StopFailure with matcher `rate_limit`, no PermissionRequest,
/// with the user's own hooks around and inside Hangar's (a user StopFailure, a mixed Notification group).
private let oldInstall = #"""
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
      },
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
    "PreToolUse": [
      {
        "matcher": "Task|Agent",
        "hooks": [
          {
            "type": "command",
            "command": "/A/hangar event subagent-start",
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
            "command": "notify-send hi"
          },
          {
            "type": "command",
            "command": "/A/hangar event notification",
            "timeout": 5
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/A/hangar event subagent-stop",
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
      },
      {
        "matcher": "server_error",
        "hooks": [
          {
            "type": "command",
            "command": "my-alert.sh"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "my-guard.sh"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "/A/hangar statusline"
  },
  "permissions": {
    "allow": [
      "Bash(ls:*)"
    ]
  }
}

"""#

private func obj(_ v: JSONValue?) -> [JSONMember] { if case .object(let m)? = v { return m }; return [] }
private func arr(_ v: JSONValue?) -> [JSONValue] { if case .array(let a)? = v { return a }; return [] }
private func str(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
private func get(_ v: JSONValue?, _ k: String) -> JSONValue? { obj(v).first { $0.key == k }?.value }

/// Every handler in file order as `event|matcher|command`.
private func handlers(_ text: String) throws -> [String] {
    obj(get(try parseJSON(text), "hooks")).flatMap { ev in
        arr(ev.value).flatMap { g in
            arr(get(g, "hooks")).map { "\(ev.key)|\(str(get(g, "matcher")) ?? "")|\(str(get($0, "command")) ?? "")" }
        }
    }
}

private func userHandlers(_ text: String) throws -> [String] {
    try handlers(text).filter { !isHangarCommand(String($0.split(separator: "|", omittingEmptySubsequences: false).last!)) }
}

@Test func upgradeAddsOnlyMissingHangarHooks() throws {
    let out = try #require(try claudeUpgrade(oldInstall, cli: "/A/hangar"))
    #expect(claudeState(out, cli: "/A/hangar") == .installed)
    // The user's handlers: same entries, same order, the mixed group keeps its user handler.
    #expect(try userHandlers(out) == userHandlers(oldInstall))
    #expect(try userHandlers(out) == ["Stop||say done", "Notification||notify-send hi", "StopFailure|server_error|my-alert.sh",
                                      "PermissionRequest|Bash|my-guard.sh"])
    // Hangar's entries already present stay where they were; only the new ones are appended.
    let before = try handlers(oldInstall).filter { !$0.contains("stop-failure") }
    let after = try handlers(out)
    #expect(after.filter { before.contains($0) } == before)
    #expect(Set(after).subtracting(before) == ["StopFailure||/A/hangar event stop-failure", "PermissionRequest||/A/hangar event permission-request"])
    // Obsolete rate_limit entry migrated; user StopFailure kept before the new one.
    #expect(after.filter { $0.hasPrefix("StopFailure") } == ["StopFailure|server_error|my-alert.sh", "StopFailure||/A/hangar event stop-failure"])
    #expect(after.filter { $0.hasPrefix("PermissionRequest") } == ["PermissionRequest|Bash|my-guard.sh", "PermissionRequest||/A/hangar event permission-request"])
    // Other keys and their order untouched; the statusLine is not Hangar's business here.
    let root = try parseJSON(out), old = try parseJSON(oldInstall)
    #expect(obj(root).map(\.key) == obj(old).map(\.key))
    #expect(obj(get(root, "hooks")).map(\.key) == obj(get(old, "hooks")).map(\.key))
    for key in ["model", "statusLine", "permissions"] { #expect(get(root, key) == get(old, key)) }
}

@Test func upgradeIsIdempotent() throws {
    let once = try #require(try claudeUpgrade(oldInstall, cli: "/A/hangar"))
    #expect(try claudeUpgrade(once, cli: "/A/hangar") == nil)
    // A current install has nothing to add either.
    #expect(try claudeUpgrade(claudeInstall(oldInstall, cli: "/A/hangar"), cli: "/A/hangar") == nil)
}

@Test func applyOffLeavesNotInstalledAlone() throws {
    func off(_ t: String?) throws -> String? { try claudeApply(t, cli: "/A/hangar", hooks: false, statusline: false, ours: { $0 == "/A/hangar" }) }
    #expect(try off(nil) == nil)
    #expect(try off("") == nil)
    #expect(try off("{}\n") == nil)
    #expect(try off(claudeUninstall(oldInstall)) == nil)
}

@Test func applyLeavesAnotherCopysEntriesAlone() throws {
    // Hooks of a CLI this copy does not own (another Hangar): a mixed set would fire twice, so nothing is written.
    #expect(throws: IntegrationError.otherCopy) { try claudeUpgrade(oldInstall, cli: "/New/hangar") }
}

@Test func applyRejectsUnparsable() {
    #expect(throws: IntegrationError.self) { try claudeUpgrade("{\"hooks\": ", cli: "/A/hangar") }
    #expect(throws: IntegrationError.self) { try claudeUpgrade("[]", cli: "/A/hangar") }
}

/// The launch's apply with every Claude function on, for the files of this suite.
private func claudeUpgrade(_ t: String?, cli: String) throws(IntegrationError) -> String? {
    try claudeApply(t, cli: cli, hooks: true, statusline: true, ours: { $0 == cli })
}

private func claudeUpgradeFile(_ url: URL, cli: String, now: Date) throws -> FileWrite? {
    try claudeApplyFile(url, cli: cli, hooks: true, statusline: true, ours: { $0 == cli }, now: now)
}

private func tmpDir() throws -> URL {
    let d = URL(fileURLWithPath: "/tmp/hg-up-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private let now = Date(timeIntervalSince1970: 1_760_000_000)

@Test func upgradeFileBacksUpAndWritesOnce() throws {
    let d = try tmpDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let url = d.appendingPathComponent("settings.json")
    try oldInstall.write(to: url, atomically: true, encoding: .utf8)

    let backup = try #require(try claudeUpgradeFile(url, cli: "/A/hangar", now: now)?.backup)
    #expect(backup.lastPathComponent.hasPrefix("settings.json.hangar-backup-"))
    #expect(try String(contentsOf: backup, encoding: .utf8) == oldInstall)
    #expect(try String(contentsOf: url, encoding: .utf8) == claudeUpgrade(oldInstall, cli: "/A/hangar"))

    // Second run: nothing written, no second backup.
    let upgraded = try String(contentsOf: url, encoding: .utf8)
    #expect(try claudeUpgradeFile(url, cli: "/A/hangar", now: now) == nil)
    #expect(try String(contentsOf: url, encoding: .utf8) == upgraded)
    #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).count == 2)
}

@Test func upgradeFileLeavesOthersUntouched() throws {
    let d = try tmpDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let url = d.appendingPathComponent("settings.json")
    // Unparsable: same bytes, no backup.
    let broken = String(oldInstall.dropLast(5))
    try broken.write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: IntegrationError.self) { try claudeUpgradeFile(url, cli: "/A/hangar", now: now) }
    #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["settings.json"])
}

/// `fresh` = a current install for /A/hangar with `edit` applied to its events.
private func editedInstall(_ edit: (inout [JSONMember]) -> Void) throws -> String {
    guard case .object(var root) = try parseJSON(claudeInstall("{}", cli: "/A/hangar")),
          let i = root.firstIndex(where: { $0.key == "hooks" }), case .object(var events) = root[i].value else { throw IntegrationError.notAnObject }
    edit(&events)
    root[i].value = .object(events)
    return printJSON(.object(root))
}

private func group(_ matcher: String?, _ commands: [String]) -> JSONValue {
    var m: [JSONMember] = matcher.map { [JSONMember(key: "matcher", value: .string($0))] } ?? []
    m.append(JSONMember(key: "hooks", value: .array(commands.map {
        .object([JSONMember(key: "type", value: .string("command")), JSONMember(key: "command", value: .string($0))])
    })))
    return .object(m)
}

/// The groups of `event` in `text`, as parsed values.
private func groups(_ text: String, _ event: String) throws -> [JSONValue] { arr(get(get(try parseJSON(text), "hooks"), event)) }

@Test func upgradeKeepsCompoundCommandsAsTheUsers() throws {
    // Commands that merely start with Hangar's CLI are the user's: never removed, even at a retired matcher.
    let compound = group(nil, ["/A/hangar event notification && say done"])
    let copied = group("rate_limit", ["/A/hangar event stop-failure; afplay x.aiff"])
    let extra = group("rate_limit", ["/A/hangar event stop-failure --verbose"])
    let old = try editedInstall { events in
        events.removeAll { $0.key == "PermissionRequest" }
        let n = events.firstIndex { $0.key == "Notification" }!
        events[n].value = .array([compound])
        let f = events.firstIndex { $0.key == "StopFailure" }!
        events[f].value = .array([copied, extra, group("rate_limit", ["/A/hangar event stop-failure"])])
    }
    let out = try #require(try claudeUpgrade(old, cli: "/A/hangar"))
    // Notification: covered by the compound command, nothing added, the group byte-for-byte the same.
    #expect(try groups(out, "Notification") == [compound])
    // StopFailure: only the exact retired entry is gone; the user's two stay first, in order. The new one is NOT added:
    // the user's commands already cover `stop-failure` in this event.
    #expect(try groups(out, "StopFailure") == [copied, extra])
    #expect(try groups(out, "PermissionRequest").count == 1)
    #expect(try claudeUpgrade(out, cli: "/A/hangar") == nil)
}

@Test func upgradeKeepsUserChangedMatcher() throws {
    // The user widened Hangar's PreToolUse matcher: kept as is, and no second subagent-start group appears.
    let widened = group("Task|Agent|Bash", ["/A/hangar event subagent-start"])
    let old = try editedInstall { events in
        events.removeAll { $0.key == "PermissionRequest" }
        let p = events.firstIndex { $0.key == "PreToolUse" }!
        events[p].value = .array([widened])
    }
    let out = try #require(try claudeUpgrade(old, cli: "/A/hangar"))
    #expect(try groups(out, "PreToolUse") == [widened])
    #expect(try groups(out, "PermissionRequest").count == 1)
    #expect(try claudeUpgrade(out, cli: "/A/hangar") == nil)
}

@Test func upgradeKeepsHangarEntryOutsideTheRetiredSet() throws {
    // An exact Hangar command in an event Hangar never used is not "previously installed": kept, nothing written.
    let stray = try editedInstall { events in events.append(JSONMember(key: "PreCompact", value: .array([group(nil, ["/A/hangar event stop"])]))) }
    #expect(try claudeUpgrade(stray, cli: "/A/hangar") == nil)
}
