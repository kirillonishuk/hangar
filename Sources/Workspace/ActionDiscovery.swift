import Foundation

/// Suggested actions from the repository (#131): `package.json` scripts of the root and its workspace packages, Makefile
/// targets, justfile recipes. Only offered in Project Settings' «Добавить действие» picker, never added by themselves.
/// The files come from two shell runs in the chat's folder (local or over ssh, `HangarUI`); everything here is parsing.

public enum PackageManager: String, Equatable, Sendable { case pnpm, yarn, bun, npm }

/// Files the first run prints (each as `\u{1e}<name>\n<content>`), and the lock files it only names (`\u{1e}lock:<name>`).
public let actionDiscoveryRootFiles = ["package.json", "pnpm-workspace.yaml", "Makefile", "makefile", "justfile", "Justfile"]
public let actionDiscoveryLockfiles = ["pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "package-lock.json"]

/// `$@`: file names. Prints each existing one (first 64 KB) after a record separator, then the lock files present.
public let actionDiscoveryRootScript = #"""
for f in "$@"; do
  case $f in lock:*) [ -f "${f#lock:}" ] && printf '\036%s\n' "$f" ;; *) [ -f "$f" ] && { printf '\036%s\n' "$f"; head -c 65536 "$f"; } ;; esac
done
exit 0
"""#

/// `$@`: workspace globs (checked by `safeWorkspaceGlob`, so they only expand). Prints each matching package's
/// `package.json` after its folder; at most 200 packages.
public let actionDiscoveryPackagesScript = #"""
n=0
for g in "$@"; do
  for d in $g; do
    [ -f "$d/package.json" ] || continue
    n=$((n + 1)); [ $n -gt 200 ] && exit 0
    printf '\036%s\n' "$d"; head -c 65536 "$d/package.json"
  done
done
exit 0
"""#

/// The runs' output → name → content.
public func parseDiscoveryDump(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for record in text.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
        let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first, !name.isEmpty else { continue }
        out[String(name)] = parts.count > 1 ? String(parts[1]) : ""
    }
    return out
}

/// `packageManager` in package.json wins («pnpm@10»), then the lock file; npm without either.
public func packageManager(lockfiles: Set<String>, packageJSON: String?) -> PackageManager {
    if let field = jsonObject(packageJSON)?["packageManager"] as? String,
       let pm = PackageManager(rawValue: String(field.prefix { $0 != "@" })) { return pm }
    if lockfiles.contains("pnpm-lock.yaml") { return .pnpm }
    if lockfiles.contains("yarn.lock") { return .yarn }
    if lockfiles.contains("bun.lockb") || lockfiles.contains("bun.lock") { return .bun }
    return .npm
}

/// Workspace globs: `packages:` of pnpm-workspace.yaml, else package.json `workspaces` (an array or `{packages: […]}`).
/// Negations and anything that is not a plain relative glob are dropped.
public func workspaceGlobs(packageJSON: String?, pnpmWorkspace: String?) -> [String] {
    var globs: [String] = []
    if let yaml = pnpmWorkspace {
        var inPackages = false
        for raw in yaml.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if !line.hasPrefix(" "), !line.hasPrefix("-"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                inPackages = line.trimmingCharacters(in: .whitespaces).hasPrefix("packages:")
                continue
            }
            let item = line.trimmingCharacters(in: .whitespaces)
            guard inPackages, item.hasPrefix("-") else { continue }
            globs.append(item.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
        }
    }
    if globs.isEmpty, let root = jsonObject(packageJSON) {
        let ws = root["workspaces"]
        globs = (ws as? [String]) ?? ((ws as? [String: Any])?["packages"] as? [String]) ?? []
    }
    return globs.filter(safeWorkspaceGlob)
}

/// A glob that only expands in `actionDiscoveryPackagesScript`: letters, digits, `_ . - / *`, relative, no `..`.
public func safeWorkspaceGlob(_ glob: String) -> Bool {
    !glob.isEmpty && !glob.hasPrefix("/") && !glob.contains("..")
        && glob.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_.-/*".unicodeScalars.contains($0) }
}

/// Lifecycle scripts npm runs by itself: never offered.
private let lifecycleScripts: Set<String> = ["preinstall", "install", "postinstall", "prepare", "prepublish", "prepublishOnly",
                                             "prepack", "postpack", "preversion", "version", "postversion"]

/// Script names of a package.json: the usual ones first (dev, start, build, test, lint), then by name.
public func packageScripts(_ packageJSON: String?) -> [String] {
    let scripts = (jsonObject(packageJSON)?["scripts"] as? [String: Any])?.keys.filter { !lifecycleScripts.contains($0) } ?? []
    let first = ["dev", "start", "build", "test", "lint"]
    return scripts.sorted { a, b in
        let (ia, ib) = (first.firstIndex(of: a) ?? first.count, first.firstIndex(of: b) ?? first.count)
        return ia != ib ? ia < ib : a < b
    }
}

/// Makefile targets defined at the line start (`name:`, not `name :=`), without special `.TARGETS` and pattern rules.
public func makeTargets(_ text: String) -> [String] {
    var out: [String] = []
    for line in text.components(separatedBy: .newlines) {
        guard let colon = line.firstIndex(of: ":"), line.first.map({ !$0.isWhitespace && $0 != "#" && $0 != "." }) == true else { continue }
        if line[colon...].hasPrefix(":=") || line[colon...].hasPrefix("::=") || line[..<colon].contains("=") { continue }
        for name in line[..<colon].split(separator: " ") where name.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) {
            if !out.contains(String(name)) { out.append(String(name)) }
        }
    }
    return out
}

/// justfile recipes (`name args…:` at the line start); settings, aliases, variables and private `_recipes` skipped.
public func justRecipes(_ text: String) -> [String] {
    var out: [String] = []
    for line in text.components(separatedBy: .newlines) {
        guard let first = line.first, first.isLetter, let colon = line.firstIndex(of: ":"), !line[colon...].hasPrefix(":=") else { continue }
        let head = line[..<colon].split(separator: " ")
        guard let name = head.first, !["set", "alias", "export", "import", "mod"].contains(String(name)),
              name.allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) }) else { continue }
        if !out.contains(String(name)) { out.append(String(name)) }
    }
    return out
}

/// One group of the picker: a package («apps/cms») or the root («» — Makefile and justfile too).
public struct ActionSuggestionGroup: Equatable, Sendable {
    public var folder: String
    public var actions: [ProjectAction]
    public init(folder: String, actions: [ProjectAction]) {
        self.folder = folder
        self.actions = actions
    }
}

/// Root files (`parseDiscoveryDump` of the first run) and packages (folder → package.json of the second) → groups:
/// root first, packages by folder. Names: a script itself at the root, «cms: dev» in a package (its folder's name).
public func actionSuggestions(root: [String: String], packages: [String: String]) -> [ActionSuggestionGroup] {
    let locks = Set(root.keys.filter { $0.hasPrefix("lock:") }.map { String($0.dropFirst(5)) })
    let pm = packageManager(lockfiles: locks, packageJSON: root["package.json"])
    var rootActions = packageScripts(root["package.json"]).map { ProjectAction(name: $0, command: "\(pm.rawValue) run \($0)") }
    if let make = root["Makefile"] ?? root["makefile"] {
        rootActions += makeTargets(make).map { ProjectAction(name: "make \($0)", command: "make \($0)") }
    }
    if let just = root["justfile"] ?? root["Justfile"] {
        rootActions += justRecipes(just).map { ProjectAction(name: "just \($0)", command: "just \($0)") }
    }
    var groups = rootActions.isEmpty ? [] : [ActionSuggestionGroup(folder: "", actions: rootActions)]
    for folder in packages.keys.sorted() {
        guard let clean = actionFolder(folder) else { continue }
        let short = clean.split(separator: "/").last.map(String.init) ?? clean
        let actions = packageScripts(packages[folder]).map {
            ProjectAction(name: "\(short): \($0)", command: "\(pm.rawValue) run \($0)", folder: clean)
        }
        if !actions.isEmpty { groups.append(ActionSuggestionGroup(folder: clean, actions: actions)) }
    }
    return groups
}

private func jsonObject(_ text: String?) -> [String: Any]? {
    text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}
