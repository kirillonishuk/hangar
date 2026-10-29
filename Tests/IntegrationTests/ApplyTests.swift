import Foundation
import Testing
@testable import Integration

private let cli = "/Applications/Hangar.app/Contents/Helpers/hangar"
private let moved = "/Users/me/Apps/Hangar.app/Contents/Helpers/hangar"
private let ours = localOwnership(cli: cli, exists: { _ in true })

private func commands(_ text: String) throws -> [String] {
    var out: [String] = []
    guard case .object(let root) = try parseJSON(text) else { return [] }
    if case .object(let events)? = root["hooks"] {
        for e in events {
            guard case .array(let groups) = e.value else { continue }
            for case .object(let g) in groups {
                guard case .array(let hs)? = g["hooks"] else { continue }
                for case .object(let h) in hs { if case .string(let c)? = h["command"] { out.append(c) } }
            }
        }
    }
    if case .object(let sl)? = root["statusLine"], case .string(let c)? = sl["command"] { out.append("statusLine: " + c) }
    return out
}

@Suite struct ClaudeApplyTests {
    private let user = #"{"model": "opus", "statusLine": {"type": "command", "command": "~/bin/line.sh"}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#

    @Test func freshInstallAndIdempotence() throws {
        let out = try #require(try claudeApply(user, cli: cli, hooks: true, statusline: true, ours: ours))
        #expect(claudeState(out, cli: cli) == .installed)
        #expect(try commands(out).contains("statusLine: \(cli) statusline --then '~/bin/line.sh'"))
        #expect(try commands(out).first == "say done")
        #expect(try claudeApply(out, cli: cli, hooks: true, statusline: true, ours: ours) == nil)
    }

    @Test func movedAppIsRetargeted() throws {
        let old = try claudeInstall(user, cli: moved)
        let out = try #require(try claudeApply(old, cli: cli, hooks: true, statusline: true, ours: ours))
        #expect(try claudeInstall(user, cli: cli) == out)
        #expect(try !commands(out).contains { $0.contains(moved) })
        #expect(try claudeApply(out, cli: cli, hooks: true, statusline: true, ours: ours) == nil)
    }

    @Test func compoundCommandOfAnOldPathStaysTheUsers() throws {
        var text = try claudeInstall("{}", cli: moved)
        text = text.replacingOccurrences(of: "\(moved) event stop\"", with: "\(moved) event stop && say hi\"")
        let out = try #require(try claudeApply(text, cli: cli, hooks: true, statusline: true, ours: ours))
        #expect(try commands(out).contains("\(moved) event stop && say hi"))
    }

    @Test func copyOutsideApplicationsLeavesTheInstalledOneAlone() throws {
        let installed = try claudeInstall(user, cli: cli)
        let downloads = "/Users/me/Downloads/Hangar.app/Contents/Helpers/hangar"
        let o = localOwnership(cli: downloads, exists: { $0 == cli })
        #expect(try claudeApply(installed, cli: downloads, hooks: true, statusline: true, ours: o) == nil)
        #expect(try claudeApply(installed, cli: downloads, hooks: false, statusline: false, ours: o) == nil)
        // The /Applications copy is gone: the entries move to this one.
        let gone = localOwnership(cli: downloads, exists: { _ in false })
        #expect(try claudeApply(installed, cli: downloads, hooks: true, statusline: true, ours: gone) == claudeInstall(user, cli: downloads))
    }

    @Test func hooksOffRemovesOnlyHangarsExactEntries() throws {
        var text = try claudeInstall(user, cli: cli)
        text = text.replacingOccurrences(of: "\(cli) event prompt\"", with: "\(cli) event prompt; afplay x\"")
        let out = try #require(try claudeApply(text, cli: cli, hooks: false, statusline: true, ours: ours))
        let c = try commands(out)
        #expect(c.filter { $0.contains(" event ") } == ["\(cli) event prompt; afplay x"])
        #expect(c.contains("say done"))
        #expect(c.contains("statusLine: \(cli) statusline --then '~/bin/line.sh'"))
        // Nothing of Hangar's hooks left at all: the hooks key holds only the user's.
        let none = try #require(try claudeApply(claudeInstall("{}", cli: cli), cli: cli, hooks: false, statusline: true, ours: ours))
        #expect(!none.contains("\"hooks\""))
    }

    @Test func statuslineOffRestoresTheUsersLine() throws {
        let text = try claudeInstall(user, cli: cli)
        let out = try #require(try claudeApply(text, cli: cli, hooks: true, statusline: false, ours: ours))
        #expect(try commands(out).contains("statusLine: ~/bin/line.sh"))
        // Hangar's own line without a wrapped one: the key goes.
        let bare = try claudeInstall("{}", cli: cli)
        let off = try #require(try claudeApply(bare, cli: cli, hooks: true, statusline: false, ours: ours))
        #expect(!off.contains("statusLine"))
        // All off on a fresh install: back to the user's file.
        #expect(try claudeApply(text, cli: cli, hooks: false, statusline: false, ours: ours).map { try parseJSON($0) } == parseJSON(user))
    }
}

@Suite struct CodexApplyTests {
    @Test func installRetargetRemove() throws {
        let user = "model = \"o3\"\nnotify = [\"say\", \"hi\"]\n\n[tui]\nx = 1\n"
        let on = try #require(try codexApply(user, cli: cli, notify: true, ours: ours))
        #expect(codexState(on, cli: cli) == .installed)
        #expect(try codexApply(on, cli: cli, notify: true, ours: ours) == nil)
        let old = try codexInstall(user, cli: moved)
        #expect(try codexApply(old, cli: cli, notify: true, ours: ours) == on)
        #expect(try codexApply(on, cli: cli, notify: false, ours: ours) == user)
        #expect(try codexApply(user, cli: cli, notify: false, ours: ours) == nil)
    }

    @Test func anotherCopysNotifyIsLeftAlone() throws {
        let downloads = "/Users/me/Downloads/Hangar.app/Contents/Helpers/hangar"
        let o = localOwnership(cli: downloads, exists: { $0 == cli })
        let installed = try codexInstall(nil, cli: cli)
        #expect(try codexApply(installed, cli: downloads, notify: true, ours: o) == nil)
        #expect(try codexApply(installed, cli: downloads, notify: false, ours: o) == nil)
    }

    @Test func remoteNotifyIsHangars() throws {
        let remote = "/home/u/.hangar/bin/hangar-remote"
        let on = try codexInstall(nil, cli: remote)
        #expect(codexState(on, cli: remote) == .installed)
        #expect(try codexApply(on, cli: remote, notify: false, ours: remoteOwnership(cli: remote))?.contains("notify") == false)
    }
}
