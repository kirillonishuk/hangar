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

@Test func upgradeLeavesNotInstalledAlone() throws {
    #expect(try claudeUpgrade(nil, cli: "/A/hangar") == nil)
    #expect(try claudeUpgrade("", cli: "/A/hangar") == nil)
    #expect(try claudeUpgrade("{}\n", cli: "/A/hangar") == nil)
    let userOnly = try claudeUninstall(oldInstall)
    #expect(try claudeUpgrade(userOnly, cli: "/A/hangar") == nil)
    // Only Hangar's statusLine, hooks removed by the user: not an installed hook set.
    #expect(try claudeUpgrade(#"{"statusLine": {"type": "command", "command": "/A/hangar statusline"}}"#, cli: "/A/hangar") == nil)
}

@Test func upgradeSkipsMovedApp() throws {
    // Hooks of another CLI path need the consent sheet (it rewrites them); a mixed set would fire twice.
    #expect(try claudeUpgrade(oldInstall, cli: "/New/hangar") == nil)
}

@Test func upgradeRejectsUnparsable() {
    #expect(throws: IntegrationError.self) { try claudeUpgrade("{\"hooks\": ", cli: "/A/hangar") }
    #expect(throws: IntegrationError.self) { try claudeUpgrade("[]", cli: "/A/hangar") }
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

    let backup = try #require(try claudeUpgradeFile(url, cli: "/A/hangar", now: now))
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
    // Missing file: nothing created.
    #expect(try claudeUpgradeFile(url, cli: "/A/hangar", now: now) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    // Not installed and unparsable: same bytes, no backup.
    let userOnly = try claudeUninstall(oldInstall)
    try userOnly.write(to: url, atomically: true, encoding: .utf8)
    #expect(try claudeUpgradeFile(url, cli: "/A/hangar", now: now) == nil)
    #expect(try String(contentsOf: url, encoding: .utf8) == userOnly)
    let broken = String(oldInstall.dropLast(5))
    try broken.write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: IntegrationError.self) { try claudeUpgradeFile(url, cli: "/A/hangar", now: now) }
    #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["settings.json"])
}

@Test func upgradeDropsObsoleteHangarEntryEvenWithNothingMissing() throws {
    // A current install plus a stray Hangar handler in an event Hangar no longer uses, and a user hook there too.
    guard case .object(var root) = try parseJSON(claudeInstall("{}", cli: "/A/hangar")) else { Issue.record(); return }
    let i = try #require(root.firstIndex { $0.key == "hooks" })
    guard case .object(var events) = root[i].value else { Issue.record(); return }
    let stray: JSONValue = .object([JSONMember(key: "hooks", value: .array([.object([
        JSONMember(key: "type", value: .string("command")), JSONMember(key: "command", value: .string("/A/hangar event stop")),
    ])]))])
    events.append(JSONMember(key: "PreCompact", value: .array([stray])))
    root[i].value = .object(events)
    let withStray = printJSON(.object(root))
    #expect(claudeState(withStray, cli: "/A/hangar") == .outdated)
    let out = try #require(try claudeUpgrade(withStray, cli: "/A/hangar"))
    #expect(claudeState(out, cli: "/A/hangar") == .installed)
    #expect(!out.contains("PreCompact"))  // emptied by the removal: the event goes too
    #expect(try claudeUpgrade(out, cli: "/A/hangar") == nil)
}
