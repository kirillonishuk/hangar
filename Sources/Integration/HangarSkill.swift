import Foundation

/// Hangar's own skill file carries this line (with its version): only such a file is replaced or removed.
public let hangarSkillMarker = "<!-- hangar-skill v"

/// `<agent dir>/skills/hangar/SKILL.md`: Claude Code (`~/.claude`) and Codex (`~/.codex`) read skills from there.
public func hangarSkillURL(agentDir: URL) -> URL {
    agentDir.appendingPathComponent("skills/hangar/SKILL.md")
}

public enum SkillEntry: Equatable, Sendable {
    case absent, current
    /// Hangar's, but another version (or edited): rewritten.
    case stale
    /// Someone else's `hangar` skill: never touched.
    case foreign
}

public func skillEntry(_ text: String?, bundled: String) -> SkillEntry {
    guard let text else { return .absent }
    if text == bundled { return .current }
    return text.contains(hangarSkillMarker) ? .stale : .foreign
}

/// Brings the skill file to `bundled` (nil: Hangar's file removed, then its empty folder). Writes back up the old bytes in
/// `backupDir`; a foreign file is an error when installing and left alone when removing. Returns the write, nil if nothing changed.
public func skillApplyFile(_ url: URL, bundled: String?, now: Date, backupDir: URL) throws -> FileWrite? {
    let existing = try readUserFile(url)
    let entry = skillEntry(existing, bundled: bundled ?? "")
    guard let bundled else {
        guard let existing, entry == .stale || entry == .current else { return nil }
        let backup = try removeUserFile(url, expected: existing, now: now, backupDir: backupDir)
        let dir = url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? FileManager.default.removeItem(at: dir) }
        return FileWrite(backup: backup)
    }
    switch entry {
    case .current: return nil
    case .foreign: throw IntegrationError.foreignSkill
    case .absent, .stale:
        return FileWrite(backup: try writeUserFile(url, text: bundled, expected: existing, now: now, backupDir: backupDir))
    }
}
