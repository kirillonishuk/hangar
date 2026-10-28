import Exec
import Foundation

/// Hangar's status line in projects that set their own (#103): Claude Code prefers a project's `.claude/settings.json`
/// over the user's file, so Hangar puts its command into the project's `.claude/settings.local.json` (higher still).
/// `--project` marks a key Hangar added: reverting removes it. A local line of the user's own is wrapped instead
/// (`--then`) and reverting restores its command. Other keys are never touched.

private func projectStatuslineCommand(_ cli: String, then: String) -> String {
    "\(shellQuote(cli)) statusline --project --then \(shellQuote(then))"
}

private func statusLine(_ root: [JSONMember]) -> (object: [JSONMember], command: String)? {
    guard case .object(let sl)? = root["statusLine"], case .string(let c)? = sl["command"] else { return nil }
    return (sl, c)
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

/// Whether a project's local settings carry Hangar's line (added or wrapped by `projectStatuslineApply`).
public func projectHasHangarStatusline(_ local: String?) -> Bool {
    guard let root = try? rootObject(local), let c = statusLine(root)?.command else { return false }
    return isHangarCommand(c)
}

/// The new `.claude/settings.local.json` that makes Claude show Hangar's line in this project; nil = nothing to write
/// (the project has no line of its own, or the local file is already current). A shared line that is gone again
/// takes Hangar's added key with it. An unparsable shared file counts as no line (Claude would not read it either).
public func projectStatuslineApply(shared: String?, local: String?, cli: String) throws(IntegrationError) -> String? {
    var root = try rootObject(local)
    let sharedLine = (try? rootObject(shared)).flatMap(statusLine).flatMap { isHangarCommand($0.command) ? nil : $0 }
    func added() -> JSONValue? {
        guard var sl = sharedLine?.object, let c = sharedLine?.command else { return nil }
        sl["command"] = .string(projectStatuslineCommand(cli, then: c))
        return .object(sl)
    }
    switch root["statusLine"] {
    case nil:
        guard let value = added() else { return nil }
        root["statusLine"] = value
    case .object(var sl)?:
        guard case .string(let c)? = sl["command"] else { return nil }  // shortcut: no string command, left as the user's
        if !isHangarCommand(c) {
            sl["command"] = .string(statuslineCommand(cli, then: c))
            root["statusLine"] = .object(sl)
        } else if shellWords(c)?.contains("--project") == true {
            let value = added()
            guard value != root["statusLine"] else { return nil }
            root["statusLine"] = value
        } else {
            let updated = statuslineCommand(cli, then: thenArgument(c))
            guard updated != c else { return nil }
            sl["command"] = .string(updated)
            root["statusLine"] = .object(sl)
        }
    default: return nil
    }
    return printJSON(.object(root))
}

/// Takes back exactly what `projectStatuslineApply` did: its added key goes, a wrapped command is restored.
/// nil = nothing of Hangar's there.
// shortcut: a file Hangar created stays as `{}`, deleting a file in the user's repo is riskier than an empty object
public func projectStatuslineRevert(local: String?) throws(IntegrationError) -> String? {
    var root = try rootObject(local)
    guard let line = statusLine(root), isHangarCommand(line.command), let words = shellWords(line.command), words[1] == "statusline"
    else { return nil }
    if words.contains("--project") {
        root["statusLine"] = nil
    } else {
        guard let then = thenArgument(line.command) else { return nil }
        var sl = line.object
        sl["command"] = .string(then)
        root["statusLine"] = .object(sl)
    }
    return printJSON(.object(root))
}
