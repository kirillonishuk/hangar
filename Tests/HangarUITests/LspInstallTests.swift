import Foundation
import Testing
@testable import HangarUI
import TestSupport
import Update

/// Language servers downloaded from Settings (#100): where they are found, the install commands, the rust-analyzer
/// download from a local feed, removal of Hangar's own folders only, and the editors looking again afterwards.
@MainActor @Suite(.serialized) struct LspInstallTests {
    static let fakeNpm = #"""
    #!/bin/sh
    d=$(dirname "$0")
    for a in "$@"; do printf '%s\n' "$a"; done > "$d/npm.args"
    [ -e "$d/slow" ] && sleep 30
    [ -e "$d/fail" ] && { echo "npm ERR! boom" >&2; exit 1; }
    prefix=$3
    mkdir -p "$prefix/node_modules/pyright" "$prefix/node_modules/.bin"
    printf '{"version":"1.1.400"}' > "$prefix/node_modules/pyright/package.json"
    printf '#!/bin/sh\n' > "$prefix/node_modules/pyright/langserver.index.js"
    chmod +x "$prefix/node_modules/pyright/langserver.index.js"
    ln -s ../pyright/langserver.index.js "$prefix/node_modules/.bin/pyright-langserver"
    """#

    static let fakeGo = #"""
    #!/bin/sh
    if [ "$1" = version ]; then printf '%s: go1.23\n\tpath\tgolang.org/x/tools/gopls\n\tmod\tgolang.org/x/tools/gopls\tv0.16.2\th1:abc=\n' "$3"; exit 0; fi
    printf '%s\n' "$@" "GOBIN=$GOBIN" > "$(dirname "$0")/go.args"
    printf '#!/bin/sh\n' > "$GOBIN/gopls"
    chmod +x "$GOBIN/gopls"
    """#

    let root: String
    let dir: String
    let bin: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/hg lsp-установка-" + UUID().uuidString
        dir = root + "/Application Support/Hangar/lsp"
        bin = root + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    }

    private func touch(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try writeScript("#!/bin/sh\n", to: path)
    }

    private func mark(_ package: LspPackage, version: String) throws {
        try touch(dir + "/" + package.relativeExecutable)
        try JSONEncoder().encode(LspInstaller.Marker(version: version))
            .write(to: URL(fileURLWithPath: dir + "/" + package.rawValue + "/" + LspInstaller.marker))
    }

    /// A releases/latest answer and its gzipped asset, as a file:// feed.
    private func feed(tag: String = "2026-10-20", asset: String = LspInstaller.rustAsset, url: String? = nil) throws -> URL {
        let src = root + "/feed"
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try Data("RA-BINARY\n".utf8).write(to: URL(fileURLWithPath: src + "/ra"))
        let gz = Process()
        gz.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gz.arguments = ["-f", src + "/ra"]
        try gz.run()
        gz.waitUntilExit()
        let assetURL = url ?? URL(fileURLWithPath: src + "/ra.gz").absoluteString
        let json = #"{"tag_name":"\#(tag)","assets":[{"name":"\#(asset)","browser_download_url":"\#(assetURL)"}]}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: src + "/latest.json"))
        return URL(fileURLWithPath: src + "/latest.json")
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(".") }
    }

    // MARK: Discovery

    @Test func hangarFolderComesAfterTheUsersOwnInstalls() async {
        let home = "/Users/u", hangar = "/S/lsp"
        func find(_ lang: LspLanguage, _ present: Set<String>, toolchain: String? = nil) async -> LspFound? {
            await LspMap.find(lang, projectRoot: "/w/p", path: ["/opt/x/bin"], home: home, hangarDir: hangar,
                              isExecutable: { present.contains($0) }, toolchain: { _ in toolchain })
        }
        #expect(await find(.rust, ["/S/lsp/rust-analyzer/rust-analyzer"])?.executable == "/S/lsp/rust-analyzer/rust-analyzer")
        #expect(await find(.rust, ["/S/lsp/rust-analyzer/rust-analyzer", "/opt/x/bin/rust-analyzer"])?.executable == "/opt/x/bin/rust-analyzer")
        #expect(await find(.go, ["/S/lsp/gopls/gopls", "/Users/u/go/bin/gopls"])?.executable == "/Users/u/go/bin/gopls")
        #expect(await find(.python, ["/S/lsp/pyright/node_modules/.bin/pyright-langserver", "/w/p/.venv/bin/pylsp"])?.executable
            == "/w/p/.venv/bin/pylsp")
        #expect(await find(.python, ["/S/lsp/pyright/node_modules/.bin/pyright-langserver"])
            == LspFound(executable: "/S/lsp/pyright/node_modules/.bin/pyright-langserver", args: ["--stdio"]))
        // Swift has no Hangar copy: xcrun stays its source.
        #expect(await find(.swift, ["/X/sourcekit-lsp"], toolchain: "/X/sourcekit-lsp")?.executable == "/X/sourcekit-lsp")
    }

    @Test func statusShowsWhereEachServerComesFrom() async throws {
        let proj = root + "/proj"
        try touch(proj + "/.venv/bin/pylsp")
        try touch(bin + "/gopls")
        try touch(bin + "/npm")
        try mark(.rustAnalyzer, version: "2026-10-20")
        let (bin, project, root) = (bin, proj, root)
        // Only this test's files exist (not the Mac's own /opt/homebrew/bin, /usr/local/bin).
        let isExecutable: @Sendable (String) -> Bool = { $0 == "/X/sourcekit-lsp" || ($0.hasPrefix(root) && FileManager.default.isExecutableFile(atPath: $0)) }
        let model = LspServersModel(env: .init(dir: dir, home: root + "/home", path: { bin }, projectRoot: { project },
                                               toolchain: { $0 == "sourcekit-lsp" ? "/X/sourcekit-lsp" : nil }, isExecutable: isExecutable))
        let row = { (id: String) in LspServersModel.rows.first { $0.id == id }! }
        #expect(model.status(row("go")) == .checking)
        await model.refresh()
        #expect(model.status(row("python")) == .installed(.project, executable: project + "/.venv/bin/pylsp"))
        #expect(model.status(row("go")) == .installed(.path, executable: bin + "/gopls"))
        #expect(model.status(row("rust")) == .installed(.hangar("2026-10-20"), executable: dir + "/rust-analyzer/rust-analyzer"))
        #expect(model.status(row("swift")) == .installed(.toolchain, executable: "/X/sourcekit-lsp"))
        #expect(model.owned == Set<LspPackage>([.rustAnalyzer]))
        #expect(model.tools[.pyright] == bin + "/npm")
        #expect(model.tools[.gopls] == nil)  // «Нужен Go»

        // No visible session: nothing project-local; nothing anywhere → missing.
        let empty = LspServersModel(env: .init(dir: root + "/none", home: root + "/home", path: { nil }, projectRoot: { nil },
                                               isExecutable: isExecutable))
        await empty.refresh()
        #expect(empty.status(row("python")) == .missing)
        #expect(empty.status(row("rust")) == .missing)
        #expect(empty.tools.isEmpty)
    }

    // MARK: Commands

    @Test func installCommandsAreArgvWithoutInjection() {
        let staging = "/S/a b/$(rm -rf ~); `x` 'q'"
        let npm = LspInstaller.command(.pyright, staging: staging, tool: "/opt/bin/npm", path: "/opt/bin:/usr/bin", environment: ["HOME": "/h"])
        #expect(npm == .init(executable: "/opt/bin/npm", args: ["install", "--prefix", staging, "--no-audit", "--no-fund", "pyright"],
                             env: ["HOME": "/h", "PATH": "/opt/bin:/usr/bin", "npm_config_update_notifier": "false"]))
        let go = LspInstaller.command(.gopls, staging: staging, tool: "/opt/go/bin/go", path: nil, environment: ["PATH": "/bin"])
        #expect(go == .init(executable: "/opt/go/bin/go", args: ["install", "golang.org/x/tools/gopls@latest"],
                            env: ["PATH": "/opt/go/bin:/bin", "GOBIN": staging]))
        #expect(LspInstaller.command(.gopls, staging: staging, tool: "go", path: nil) == nil)
        #expect(LspInstaller.command(.rustAnalyzer, staging: staging, tool: "/x", path: nil) == nil)
        #expect(LspInstaller.goplsVersion("x: go1\n\tpath\tgolang.org/x/tools/gopls\n\tmod\tgolang.org/x/tools/gopls\tv0.16.2\th1:a\n") == "v0.16.2")
        #expect(LspInstaller.goplsVersion("\tmod\tgolang.org/x/tools/gopls\tv1;$(x)\n") == nil)
        #expect(LspInstaller.tool("npm", path: ["/usr/bin", "rel", "/a"], home: "/h", isExecutable: { $0 == "/usr/bin/npm" || $0 == "/a/npm" }) == "/a/npm")
    }

    @Test func npmAndGoInstallWithTheUsersTools() async throws {
        try writeScript(Self.fakeNpm, to: bin + "/npm")
        try writeScript(Self.fakeGo, to: bin + "/go")
        #expect(try await LspInstaller.install(.pyright, dir: dir, tool: bin + "/npm", path: bin + ":/bin:/usr/bin") == "1.1.400")
        #expect(FileManager.default.isExecutableFile(atPath: dir + "/" + LspPackage.pyright.relativeExecutable))
        #expect(LspInstaller.installed(.pyright, in: dir)?.version == "1.1.400")
        let npmArgs = try String(contentsOfFile: bin + "/npm.args", encoding: .utf8).split(separator: "\n")
        #expect(npmArgs.count == 6 && npmArgs[2].hasPrefix(dir + "/.pyright-"))

        #expect(try await LspInstaller.install(.gopls, dir: dir, tool: bin + "/go", path: bin + ":/bin:/usr/bin") == "v0.16.2")
        #expect(LspInstaller.installed(.gopls, in: dir)?.version == "v0.16.2")
        #expect(try String(contentsOfFile: bin + "/go.args", encoding: .utf8).contains("GOBIN=" + dir + "/.gopls-"))
        #expect(leftovers().isEmpty)

        // A failing tool: its output is the error, nothing is left behind, the old install stays.
        FileManager.default.createFile(atPath: bin + "/fail", contents: nil)
        await #expect(throws: LspInstallError.tool(1, "npm ERR! boom")) {
            try await LspInstaller.install(.pyright, dir: dir, tool: bin + "/npm", path: bin + ":/bin:/usr/bin")
        }
        #expect(leftovers().isEmpty)
        #expect(LspInstaller.installed(.pyright, in: dir)?.version == "1.1.400")
    }

    // MARK: rust-analyzer download

    @Test func rustAnalyzerFromALocalFeed() async throws {
        let feed = try feed()
        let version = try await LspInstaller.install(.rustAnalyzer, dir: dir, tool: nil, path: nil, feed: feed, trusted: { $0.isFileURL })
        #expect(version == "2026-10-20")
        let exe = dir + "/" + LspPackage.rustAnalyzer.relativeExecutable
        #expect(FileManager.default.contents(atPath: exe) == Data("RA-BINARY\n".utf8))  // gunzipped
        #expect(FileManager.default.isExecutableFile(atPath: exe))
        #expect(!FileManager.default.fileExists(atPath: exe + ".gz"))
        #expect(LspInstaller.installed(.rustAnalyzer, in: dir)?.version == "2026-10-20")
        #expect(leftovers().isEmpty)
    }

    @Test func rustAnalyzerOnlyFromTrustedHosts() async throws {
        let asset = LspInstaller.rustAsset
        func parse(_ url: String, tag: String = "2026-10-20") -> URL? {
            let json = #"{"tag_name":"\#(tag)","assets":[{"name":"\#(asset)","browser_download_url":"\#(url)"}]}"#
            return LspInstaller.parseRelease(Data(json.utf8), asset: asset, trusted: ReleaseFeed.isTrusted)?.url
        }
        let good = "https://github.com/rust-lang/rust-analyzer/releases/download/2026-10-20/" + asset
        #expect(parse(good)?.absoluteString == good)
        #expect(parse("https://objects.githubusercontent.com/x/" + asset) != nil)
        #expect(parse("https://evil.example/" + asset) == nil)
        #expect(parse("http://github.com/" + asset) == nil)
        #expect(parse("file:///tmp/" + asset) == nil)
        #expect(parse(good, tag: "v1 $(rm)") == nil)
        #expect(LspInstaller.parseRelease(Data(#"{"tag_name":"x","assets":[]}"#.utf8), asset: asset, trusted: { _ in true }) == nil)
        #expect(asset.hasSuffix("-apple-darwin.gz"))

        // The real feed URL is trusted; an untrusted feed or asset is refused before anything is written.
        #expect(ReleaseFeed.isTrusted(LspInstaller.rustFeed))
        await #expect(throws: LspInstallError.self) {
            try await LspInstaller.install(.rustAnalyzer, dir: dir, tool: nil, path: nil, feed: try feed())
        }
        let evil = try feed(url: "https://evil.example/" + asset)
        await #expect(throws: LspInstallError.noAsset) {
            try await LspInstaller.install(.rustAnalyzer, dir: dir, tool: nil, path: nil, feed: evil,
                                           trusted: { $0.isFileURL || ReleaseFeed.isTrusted($0) })
        }
        #expect(LspInstaller.installed(.rustAnalyzer, in: dir) == nil)
        #expect(leftovers().isEmpty)
    }

    // MARK: Removal

    @Test func removesOnlyHangarsOwnFolders() throws {
        try mark(.gopls, version: "v1")
        try LspInstaller.remove(.gopls, dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir + "/gopls"))

        // No marker: not Hangar's.
        try touch(dir + "/rust-analyzer/rust-analyzer")
        #expect(throws: LspInstallError.notOwned) { try LspInstaller.remove(.rustAnalyzer, dir: dir) }
        #expect(FileManager.default.fileExists(atPath: dir + "/rust-analyzer/rust-analyzer"))

        // A symlink to a marked folder elsewhere: refused, the target untouched.
        let elsewhere = root + "/elsewhere"
        try touch(elsewhere + "/node_modules/.bin/pyright-langserver")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: elsewhere + "/" + LspInstaller.marker))
        try FileManager.default.createSymbolicLink(atPath: dir + "/pyright", withDestinationPath: elsewhere)
        #expect(throws: LspInstallError.notOwned) { try LspInstaller.remove(.pyright, dir: dir) }
        #expect(FileManager.default.fileExists(atPath: elsewhere + "/" + LspInstaller.marker))
        #expect(LspInstaller.installed(.pyright, in: dir) == nil)
    }

    // MARK: Settings model

    @Test func installFromSettingsTellsTheEditorsAndRefreshes() async throws {
        let feed = try feed()
        final class Counter { var n = 0 }
        let changes = Counter()
        var env = LspServersModel.Env(dir: dir, home: root + "/home", path: { nil }, projectRoot: { nil }, changed: { changes.n += 1 })
        env.feed = feed
        env.trusted = { $0.isFileURL }
        let model = LspServersModel(env: env)
        let rust = LspServersModel.rows.first { $0.id == "rust" }!
        await model.refresh()
        #expect(model.status(rust) == .missing)
        model.install(.rustAnalyzer)
        #expect(model.jobs[.rustAnalyzer] != nil)
        #expect(await waitUntil { model.status(rust) == .installed(.hangar("2026-10-20"), executable: dir + "/rust-analyzer/rust-analyzer") })
        #expect(model.jobs[.rustAnalyzer] == nil)
        #expect(changes.n == 1)
        #expect(model.owned == Set<LspPackage>([.rustAnalyzer]))

        model.remove(.rustAnalyzer)
        #expect(changes.n == 2)
        #expect(await waitUntil { model.status(rust) == .missing && model.owned.isEmpty })
    }

    @Test func cancelAndFailureInSettings() async throws {
        try writeScript(Self.fakeNpm, to: bin + "/npm")
        let bin = bin
        let model = LspServersModel(env: .init(dir: dir, home: root + "/home", path: { bin + ":/bin:/usr/bin" }, projectRoot: { nil }))
        await model.refresh()
        FileManager.default.createFile(atPath: bin + "/slow", contents: nil)
        model.install(.pyright)
        #expect(await waitUntil { FileManager.default.fileExists(atPath: bin + "/npm.args") })
        model.cancel(.pyright)
        #expect(await waitUntil { model.jobs[.pyright] == nil })
        #expect(LspInstaller.installed(.pyright, in: dir) == nil)
        #expect(leftovers().isEmpty)

        try FileManager.default.removeItem(atPath: bin + "/slow")
        FileManager.default.createFile(atPath: bin + "/fail", contents: nil)
        model.install(.pyright)
        #expect(await waitUntil { model.jobs[.pyright] == .failed("npm ERR! boom") })
    }
}
