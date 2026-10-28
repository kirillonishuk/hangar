import Exec
import Foundation

/// Hangar's status line in projects that set their own (#105): Claude Code prefers a project's `.claude/settings.json`
/// over the user's file, so Hangar puts its command into the project's `.claude/settings.local.json` (higher still).
/// Every command Hangar writes there carries a mark (`ProjectStatuslineMark`); only marked commands are ever changed
/// or taken back, so a `hangar statusline --then …` the user wrote by hand stays theirs. Other keys are never touched.
enum ProjectStatuslineMark: String, CaseIterable {
    /// The key was added to an existing local file: reverting removes the key.
    case added = "--project"
    /// Hangar created the local file for it: reverting removes the file when nothing else is left in it.
    case created = "--project-new"
    /// The user's own local command was wrapped (`--then`): reverting restores it.
    case wrapped = "--project-wrapped"
}

/// What a sync does to a project's local settings file.
public enum ProjectFileChange: Equatable, Sendable {
    case write(String)
    /// Only Hangar's key was in a file Hangar created: the file goes.
    case remove
}

private func markedCommand(_ cli: String, _ mark: ProjectStatuslineMark, then: String) -> String {
    "\(shellQuote(cli)) statusline \(mark.rawValue) --then \(shellQuote(then))"
}

private func statusLine(_ root: [JSONMember]) -> (object: [JSONMember], command: String)? {
    guard case .object(let sl)? = root["statusLine"], case .string(let c)? = sl["command"] else { return nil }
    return (sl, c)
}

/// The mark of a status line command Hangar wrote into a project; nil for anything else (the user's).
private func mark(_ command: String) -> ProjectStatuslineMark? {
    guard isHangarCommand(command), let w = shellWords(command), w[1] == "statusline", let i = w.firstIndex(of: "--then") else { return nil }
    return w[2..<i].lazy.compactMap(ProjectStatuslineMark.init(rawValue:)).first
}

/// The CLI of the user's installed Hangar status line (`<cli> statusline …`); nil when the line is not Hangar's.
public func hangarStatuslineCLI(_ userSettings: String?) -> String? {
    guard let root = try? rootObject(userSettings), let c = statusLine(root)?.command, isHangarCommand(c),
          let w = shellWords(c), w[1] == "statusline" else { return nil }
    return w[0]
}

/// The original command kept in the user's Hangar status line (`--then`), if any: what «Ваша» shows.
public func userStatuslineCommand(_ userSettings: String?) -> String? {
    guard let root = try? rootObject(userSettings), let c = statusLine(root)?.command else { return nil }
    return isHangarCommand(c) ? thenArgument(c) : c
}

/// Whether a project's local settings carry a line Hangar put there.
public func projectHasHangarStatusline(_ local: String?) -> Bool {
    guard let root = try? rootObject(local), let c = statusLine(root)?.command else { return false }
    return mark(c) != nil
}

/// The change that makes Claude show Hangar's line in this project; nil = nothing to do (no line of the project's own,
/// already current, or a Hangar command the user wrote). The `--then` snapshot follows the shared command; a shared
/// line that is gone takes Hangar's added key (or created file) with it. An unparsable shared file counts as no line.
public func projectStatuslineApply(shared: String?, local: String?, cli: String) throws(IntegrationError) -> ProjectFileChange? {
    var root = try rootObject(local)
    let sharedLine = (try? rootObject(shared)).flatMap(statusLine).flatMap { isHangarCommand($0.command) ? nil : $0 }
    func added(_ m: ProjectStatuslineMark) -> JSONValue? {
        guard var sl = sharedLine?.object, let c = sharedLine?.command else { return nil }
        sl["command"] = .string(markedCommand(cli, m, then: c))
        return .object(sl)
    }
    switch root["statusLine"] {
    case nil:
        guard let value = added(local == nil ? .created : .added) else { return nil }
        root["statusLine"] = value
    case .object(var sl)?:
        guard case .string(let c)? = sl["command"] else { return nil }  // shortcut: no string command, left as the user's
        if !isHangarCommand(c) {
            sl["command"] = .string(markedCommand(cli, .wrapped, then: c))
            root["statusLine"] = .object(sl)
        } else {
            switch mark(c) {
            case nil: return nil
            case .wrapped?:
                guard let then = thenArgument(c) else { return nil }
                let updated = markedCommand(cli, .wrapped, then: then)
                guard updated != c else { return nil }
                sl["command"] = .string(updated)
                root["statusLine"] = .object(sl)
            case let m?:
                guard let value = added(m) else { return try projectStatuslineRevert(local: local) }
                guard value != root["statusLine"] else { return nil }
                root["statusLine"] = value
            }
        }
    default: return nil
    }
    return .write(printJSON(.object(root)))
}

/// Takes back exactly what `projectStatuslineApply` did: an added key goes (with the file, if Hangar created it and
/// nothing else is in it), a wrapped command is restored. nil = nothing of Hangar's there.
public func projectStatuslineRevert(local: String?) throws(IntegrationError) -> ProjectFileChange? {
    var root = try rootObject(local)
    guard let line = statusLine(root), let m = mark(line.command) else { return nil }
    switch m {
    case .added, .created:
        root["statusLine"] = nil
        if m == .created && root.isEmpty { return .remove }
    case .wrapped:
        guard let then = thenArgument(line.command) else { return nil }
        var sl = line.object
        sl["command"] = .string(then)
        root["statusLine"] = .object(sl)
    }
    return .write(printJSON(.object(root)))
}
