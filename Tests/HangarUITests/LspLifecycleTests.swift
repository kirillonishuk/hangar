import Foundation
import Testing
@testable import HangarUI

/// LSP servers end to end (#90): a shell script plays the server — framed JSON-RPC both ways, initialize handshake,
/// a server → client request, diagnostics, request/response correlation, grace stop, one restart after a crash.
@MainActor @Suite(.serialized) struct LspLifecycleTests {
    static let fake = #"""
    #!/bin/sh
    log=$1; mode=$2
    echo start >> "$log"
    send() { printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1"; }
    while :; do
      len=
      while IFS= read -r h; do
        h=$(printf '%s' "$h" | tr -d '\r')
        [ -z "$h" ] && break
        case "$h" in Content-Length:*) len=${h#Content-Length: };; esac
      done
      [ -z "$len" ] && exit 0
      body=$(dd bs=1 count="$len" 2>/dev/null)
      method=$(printf '%s' "$body" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
      id=$(printf '%s' "$body" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      uri=$(printf '%s' "$body" | sed -n 's/.*"uri":"\([^"]*\)".*/\1/p')
      case "$method" in
      "") echo "reply $(printf '%s' "$body" | sed -n 's/.*"result":\(\[[^]]*\]\).*/\1/p')" >> "$log"; continue;;
      textDocument/didChange) echo "$method $uri $(printf '%s' "$body" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')" >> "$log";;
      *) echo "$method $uri" >> "$log";;
      esac
      case "$method" in
      initialize)
        # A request of the server's own first: answered by the client before anything else is logged.
        send '{"jsonrpc":"2.0","id":"cfg","method":"workspace/configuration","params":{"items":[{"section":"a"},{"section":"b"}]}}'
        send '{"jsonrpc":"2.0","id":'"$id"',"result":{"capabilities":{"textDocumentSync":{"change":2},"hoverProvider":true,"definitionProvider":true,"renameProvider":{"prepareProvider":true}}}}';;
      textDocument/didOpen)
        case "$uri" in *crash*) if [ "$mode" = always ] || [ ! -e "$log.crashed" ]; then : > "$log.crashed"; exit 3; fi;; esac
        send '{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"noise"}}'
        send '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"'"$uri"'","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"severity":1,"message":"bad","source":"fake"}]}}';;
      textDocument/hover)
        # Answers out of order: an unknown id first, then the real one.
        send '{"jsonrpc":"2.0","id":99999,"result":{"contents":"stale"}}'
        send '{"jsonrpc":"2.0","id":'"$id"',"result":{"contents":{"kind":"markdown","value":"**x**: int"}}}';;
      textDocument/definition)
        send '{"jsonrpc":"2.0","id":'"$id"',"result":[{"uri":"file:///etc/passwd","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}},{"uri":"'"$uri"'","range":{"start":{"line":2,"character":4},"end":{"line":2,"character":5}}}]}';;
      textDocument/prepareRename) send '{"jsonrpc":"2.0","id":'"$id"',"result":null}';;
      shutdown) send '{"jsonrpc":"2.0","id":'"$id"',"result":null}';;
      exit) exit 0;;
      esac
    done
    """#

    final class Sink {
        var commands: [EditorCommand] = []
        var statuses: [LanguageStatus?] {
            commands.compactMap { if case .language(_, let s) = $0 { return s } else { return nil } }
        }
        var markers: [[EditorDiagnostic]] {
            commands.compactMap { if case .markers(_, let m) = $0 { return m } else { return nil } }
        }
    }

    let dir: String
    let log: String
    let script: String

    init() throws {
        dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/hg-lsp-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        log = dir + "/log"
        script = dir + "/fake-lsp"
        try writeScript(Self.fake, to: script)
    }

    final class Counter { var n = 0 }

    private func lsp(found: Bool = true, mode: String = "", grace: Duration = .seconds(30), finds: Counter = Counter(),
                     stableAfter: Duration = .seconds(60), executable: (() -> String)? = nil) -> Languages {
        let (script, log) = (script, log)
        let lsp = LspLanguages(find: { _, _ in
            finds.n += 1
            return found ? LspFound(executable: executable?() ?? script, args: [log, mode]) : nil
        }, grace: grace, stableAfter: stableAfter)
        return Languages(lookup: { _, _, _ in .noTypeScript }, launch: { _, _ in nil }, lsp: lsp)
    }

    private func owner(_ sink: Sink, id: UUID = UUID(), text: String = "x = 1\n") -> Languages.Owner {
        Languages.Owner(id: id, root: dir, send: { sink.commands.append($0) }, text: { _ in text })
    }

    private func logLines() -> [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Counts polls, not wall-clock time: a loaded full run stretches the sleeps, not the number of checks.
    private func waitUntil(polls: Int = 1500, _ cond: () -> Bool) async -> Bool {
        for _ in 0..<polls {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    private func uri(_ path: String) -> String { LspMap.uri(path) }

    @Test func handshakeSyncDiagnosticsAndRequests() async throws {
        let langs = lsp()
        let sink = Sink()
        let file = dir + "/a.py"
        langs.opened(dir + "/notes.txt", text: "", host: nil, owner: owner(sink))  // no language server: nothing starts
        langs.opened(file, text: "x = 1\n", host: "server", owner: owner(sink))   // remote: out of scope, nothing starts
        try await Task.sleep(for: .milliseconds(100))
        #expect(logLines().isEmpty)

        langs.opened(file, text: "x = 1\n", host: nil, owner: owner(sink))
        // An edit made before the server is initialized is sent after `didOpen`.
        langs.edited(file, [EditorEdit(line: 1, column: 5, endLine: 1, endColumn: 6, text: "2")], host: nil)
        #expect(await waitUntil { logLines().contains("textDocument/didChange \(uri(file)) 2") })
        let lines = logLines()
        #expect(lines.first == "start")
        #expect(lines.dropFirst().prefix(5) == ["initialize \(uri(dir))", "reply [null,null]", "initialized ", "textDocument/didOpen \(uri(file))",
                                                "textDocument/didChange \(uri(file)) 2"])
        #expect(await waitUntil { sink.markers.contains { $0 == [EditorDiagnostic(line: 1, column: 1, endLine: 1, endColumn: 4, severity: .error, message: "bad (fake)")] } })
        #expect(await waitUntil { sink.statuses.last??.level == .ready })

        let hover = await langs.request(ProviderRequest(id: 1, kind: .hover, file: file, line: 1, column: 1), host: nil) { _ in nil }
        #expect(hover == .hover(markdown: "**x**: int"))
        // Definitions outside the project are dropped.
        let def = await langs.request(ProviderRequest(id: 2, kind: .definition, file: file, line: 1, column: 1), host: nil) { _ in nil }
        #expect(def == .locations([EditorLocation(path: file, line: 3, column: 5, endLine: 3, endColumn: 6)], previews: [:]))
        // Not offered by the server: not asked.
        let refs = await langs.request(ProviderRequest(id: 3, kind: .references, file: file, line: 1, column: 1), host: nil) { _ in nil }
        #expect(refs == nil)
        #expect(!logLines().contains { $0.hasPrefix("textDocument/references") })
        let rename = await langs.request(ProviderRequest(id: 4, kind: .rename, file: file, line: 1, column: 1), host: nil) { _ in nil }
        #expect(rename == .rejected(L10n.editorRenameRefused))
        #expect(logLines().filter { $0 == "start" }.count == 1)
        langs.stopAll()
        #expect(await waitUntil { logLines().contains("exit ") })
    }

    @Test func missingServerIsACalmStatus() async throws {
        let langs = lsp(found: false)
        let sink = Sink()
        langs.opened(dir + "/main.go", text: "package main\n", host: nil, owner: owner(sink))
        #expect(await waitUntil { !sink.statuses.isEmpty })
        #expect(sink.statuses.last??.level == .off)
        #expect(sink.statuses.last??.text == L10n.lspMissing("Go"))
        #expect(logLines().isEmpty)
    }

    @Test func stopsAfterTheGraceOnceTheLastFileCloses() async throws {
        let langs = lsp(grace: .milliseconds(300))
        let a = dir + "/a.rs", id = UUID()
        langs.opened(a, text: "fn main() {}\n", host: nil, owner: owner(Sink(), id: id))
        #expect(await waitUntil { langs.runningCount == 1 && logLines().contains("textDocument/didOpen \(uri(a))") })
        langs.closed(a, host: nil, owner: id)
        // Reopened within the grace: the same process.
        langs.opened(a, text: "fn main() {}\n", host: nil, owner: owner(Sink(), id: id))
        try await Task.sleep(for: .milliseconds(500))
        #expect(langs.runningCount == 1)
        langs.closed(a, host: nil, owner: id)
        #expect(await waitUntil { langs.runningCount == 0 })
        #expect(await waitUntil { logLines().contains("exit ") })
        #expect(logLines().contains("textDocument/didClose \(uri(a))"))
        #expect(logLines().contains("shutdown "))
        #expect(logLines().filter { $0 == "start" }.count == 1)
    }

    @Test func restartsOnceAfterACrash() async throws {
        let langs = lsp()
        let sink = Sink()
        let file = dir + "/crash.swift"
        langs.opened(file, text: "let x = 1\n", host: nil, owner: owner(sink, text: "let x = 2\n"))
        // The first process dies on `didOpen`; the restart reopens the file (text from the page) and stays up.
        #expect(await waitUntil { logLines().filter { $0 == "textDocument/didOpen \(uri(file))" }.count == 2 })
        #expect(logLines().filter { $0 == "start" }.count == 2)
        #expect(await waitUntil { langs.runningCount == 1 && sink.statuses.last??.level == .ready })
        langs.stopAll()
    }

    @Test func stopsTryingAfterTheSecondCrash() async throws {
        let langs = lsp(mode: "always")
        let sink = Sink()
        let file = dir + "/crash.py"
        langs.opened(file, text: "x\n", host: nil, owner: owner(sink))
        #expect(await waitUntil { sink.statuses.last??.level == .off })
        #expect(logLines().filter { $0 == "start" }.count == 2)
        #expect(langs.runningCount == 0)
        // The status item's click starts it afresh.
        langs.restart(file, host: nil)
        #expect(await waitUntil { logLines().filter { $0 == "start" }.count == 3 })
        langs.stopAll()
    }

    @Test func restartLooksForTheServerAgain() async throws {
        let finds = Counter()
        let langs = lsp(finds: finds)
        let a = dir + "/a.py", b = dir + "/b.py"
        langs.opened(a, text: "x\n", host: nil, owner: owner(Sink()))
        #expect(await waitUntil { logLines().contains("textDocument/didOpen \(uri(a))") })
        #expect(finds.n == 1)
        langs.restart(a, host: nil)
        langs.opened(b, text: "y\n", host: nil, owner: owner(Sink()))
        #expect(await waitUntil { logLines().contains("textDocument/didOpen \(uri(b))") })
        #expect(finds.n == 2)
        langs.stopAll()
    }

    @Test func requestsTimeOutOrCancelWithCancelRequest() async throws {
        let server = LspServer(launch: LspLaunch(executable: script, args: [log, ""], cwd: dir))
        try server.start()
        defer { server.stop() }
        let reply = await server.request("never/answered", nil, timeout: .milliseconds(200))
        #expect(reply == nil)
        #expect(await waitUntil { logLines().filter { $0 == "$/cancelRequest " }.count == 1 })
        let task = Task { await server.request("never/answered", nil, timeout: .seconds(600)) }
        #expect(await waitUntil { logLines().filter { $0 == "never/answered " }.count == 2 })
        task.cancel()
        #expect(await task.value == nil)
        #expect(await waitUntil { logLines().filter { $0 == "$/cancelRequest " }.count == 2 })
    }

    /// Ignores SIGTERM and never reads stdin: `stop()` must not wait behind the blocked write, and SIGKILL ends it.
    static let stubborn = "#!/bin/sh\ntrap '' TERM\nexec sleep 1000\n"

    @Test func stopKillsAServerThatIgnoresEverything() async throws {
        let path = dir + "/stubborn"
        try writeScript(Self.stubborn, to: path)
        let server = LspServer(launch: LspLaunch(executable: path, args: [], cwd: dir))
        try server.start()
        server.notify("big", ["pad": String(repeating: "x", count: 1 << 20)])  // more than the pipe holds: the write blocks
        let started = ContinuousClock.now
        server.stop()
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await waitUntil { !server.isRunning })
        let ts = TsServer(launch: TsLaunch(executable: path, args: [], cwd: dir))
        try ts.start()
        ts.notify("big", ["pad": String(repeating: "x", count: 1 << 20)])
        ts.stop()
        #expect(await waitUntil { !ts.isRunning })
    }

    /// A crash after the server has been up `stableAfter` counts as a first crash again: restarted every time.
    @Test func crashAfterAStableRunIsRestartedAgain() async throws {
        let langs = lsp(mode: "always", stableAfter: .zero)
        let sink = Sink()
        langs.opened(dir + "/crash.py", text: "x\n", host: nil, owner: owner(sink))
        // With the default (60 s) it stops after 2 starts (`stopsTryingAfterTheSecondCrash`); here it keeps going.
        #expect(await waitUntil { logLines().filter { $0 == "start" }.count >= 4 })
        langs.stopAll()
    }

    /// The executable is gone (uninstalled): the status click looks for a server again and launches the new one.
    @Test func restartRediscoversAGoneExecutable() async throws {
        let first = dir + "/old-lsp", second = dir + "/new-lsp"
        try writeScript(Self.fake, to: first)
        try writeScript(Self.fake, to: second)
        final class Path { var value: String; init(_ v: String) { value = v } }
        let current = Path(first)
        let finds = Counter()
        let langs = lsp(finds: finds, executable: { current.value })
        let sink = Sink()
        let file = dir + "/a.go"
        langs.opened(file, text: "package a\n", host: nil, owner: owner(sink, text: "package b\n"))
        #expect(await waitUntil { logLines().contains("textDocument/didOpen \(uri(file))") && sink.statuses.last??.text == "old-lsp" })
        try FileManager.default.removeItem(atPath: first)
        current.value = second
        langs.restart(file, host: nil)
        #expect(await waitUntil { logLines().filter { $0 == "textDocument/didOpen \(uri(file))" }.count == 2 })
        #expect(finds.n == 2)
        #expect(await waitUntil { sink.statuses.last??.text == "new-lsp" && sink.statuses.last??.level == .ready })
        langs.stopAll()
    }
}
