import Foundation
import Testing
@testable import Integration

/// The skill file in a temp «home»: install, re-install (no-op), update, remove, foreign — always with backups.
@Test func skillInstallIsIdempotentAndOnlyTouchesItsOwnFile() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("hg-skill-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: home) }
    let backups = home.appendingPathComponent("backups")
    let url = hangarSkillURL(agentDir: home.appendingPathComponent(".claude"))
    #expect(url.path.hasSuffix("/.claude/skills/hangar/SKILL.md"))
    let v1 = "---\nname: hangar\n---\n\(hangarSkillMarker)1 -->\nbody\n", v2 = v1.replacingOccurrences(of: "v1", with: "v2") + "more\n"
    let now = Date(timeIntervalSince1970: 1_760_000_000)

    // Removing what is not there, and a first install (no backup: the file was new).
    #expect(try skillApplyFile(url, bundled: nil, now: now, backupDir: backups) == nil)
    #expect(try skillApplyFile(url, bundled: v1, now: now, backupDir: backups) == FileWrite(backup: nil))
    #expect(try String(contentsOf: url, encoding: .utf8) == v1)
    #expect(try skillApplyFile(url, bundled: v1, now: now, backupDir: backups) == nil)
    // A newer version replaces ours; the old one is kept.
    let update = try #require(try skillApplyFile(url, bundled: v2, now: now, backupDir: backups)?.backup)
    #expect(try String(contentsOf: update, encoding: .utf8) == v1)
    #expect(try String(contentsOf: url, encoding: .utf8) == v2)
    // Off: removed with a backup, the empty folder too; again: nothing.
    let removed = try #require(try skillApplyFile(url, bundled: nil, now: now.addingTimeInterval(1), backupDir: backups)?.backup)
    #expect(try String(contentsOf: removed, encoding: .utf8) == v2)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    #expect(try skillApplyFile(url, bundled: nil, now: now, backupDir: backups) == nil)

    // Someone else's `hangar` skill: refused on install, left alone on removal.
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "---\nname: hangar\n---\nmine\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(skillEntry(try readUserFile(url), bundled: v1) == .foreign)
    #expect(throws: IntegrationError.foreignSkill) { try skillApplyFile(url, bundled: v1, now: now, backupDir: backups) }
    #expect(try skillApplyFile(url, bundled: nil, now: now, backupDir: backups) == nil)
    #expect(try String(contentsOf: url, encoding: .utf8) == "---\nname: hangar\n---\nmine\n")
}
