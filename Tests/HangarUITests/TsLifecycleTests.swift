import Foundation
import Testing
@testable import HangarUI

/// One tsserver per project, started lazily, stopped after the last file + grace, restarted once on a crash (#NN-tsserver).
/// A shell script plays tsserver: it logs each command and answers a few.
@MainActor @Suite(.serialized) struct TsLifecycleTests {
    static let fake = #"""
    #!/bin/sh
    log=$1; mode=$2
    echo start >> "$log"
    reply() { printf 'Content-Length: %d\r\n\r\n%s\n' $((${#1} + 1)) "$1"; }
    while IFS= read -r line; do
      cmd=$(printf '%s' "$line" | sed -n 's/.*"command":"\([A-Za-z]*\)".*/\1/p')
      seq=$(printf '%s' "$line" | sed -n 's/.*"seq":\([0-9]*\).*/\1/p')
      file=$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
      echo "$cmd $file" >> "$log"
      case "$cmd" in
      open) case "$file" in *crash*) if [ "$mode" = always ] || [ ! -e "$log.crashed" ]; then : > "$log.crashed"; exit 3; fi;; esac;;
      geterr)
        f=$(printf '%s' "$line" | sed -n 's/.*"files":\["\([^"]*\)".*/\1/p')
        reply '{"seq":0,"type":"event","event":"semanticDiag","body":{"file":"'"$f"'","diagnostics":[{"start":{"line":1,"offset":1},"end":{"line":1,"offset":4},"text":"bad","category":"error","code":1}]}}'
        reply '{"seq":0,"type":"event","event":"someFutureEvent","body":{}}';;
      quickinfo) reply '{"seq":0,"type":"response","command":"quickinfo","request_seq":'"$seq"',"success":true,"body":{"displayString":"const x: number"}}';;
      definitionAndBoundSpan) reply '{"seq":0,"type":"response","command":"definitionAndBoundSpan","request_seq":'"$seq"',"success":true,"body":{"definitions":[{"file":"/etc/passwd","start":{"line":1,"offset":1},"end":{"line":1,"offset":2}}]}}';;
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
        dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/hg-tslife-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        log = dir + "/log"
        script = dir + "/fake-tsserver"
        try writeScript(Self.fake, to: script)
    }

    private func languages(lookup: TsLookup? = nil, mode: String = "", grace: Duration = .seconds(30)) -> Languages {
        let install = TsInstall(tsserver: dir + "/node_modules/typescript/lib/tsserver.js", version: "5.6.3", node: "/bin/sh", cwd: dir)
        let (script, log) = (script, log)
        return Languages(lookup: { _, _, _ in lookup ?? .found(install) },
                         launch: { _, i in TsLaunch(executable: script, args: [log, mode], cwd: i.cwd) },
                         grace: grace, debounce: .milliseconds(30))
    }

    private func owner(_ sink: Sink, id: UUID = UUID()) -> Languages.Owner {
        Languages.Owner(id: id, root: dir, send: { sink.commands.append($0) }, text: { _ in "let x = 1\n" })
    }

    private func logLines() -> [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func waitUntil(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    @Test func startsLazilyAnswersAndForwardsEdits() async throws {
        let langs = languages()
        let sink = Sink()
        #expect(logLines().isEmpty)
        langs.opened(dir + "/a.json", text: "{}", host: nil, owner: owner(sink))   // not TS/JS: nothing starts
        try await Task.sleep(for: .milliseconds(100))
        #expect(logLines().isEmpty)

        let file = dir + "/a.ts"
        let o = owner(sink)
        langs.opened(file, text: "let x = 1\n", host: nil, owner: o)
        // Edits made before the server is up are kept and sent after `open`.
        langs.edited(file, [EditorEdit(line: 1, column: 5, endLine: 1, endColumn: 6, text: "y")], host: nil)
        #expect(await waitUntil { logLines().contains("open \(file)") })
        langs.edited(file, [EditorEdit(line: 1, column: 9, endLine: 1, endColumn: 10, text: "2")], host: nil)
        #expect(await waitUntil { logLines().filter { $0 == "change \(file)" }.count == 2 })
        let lines = logLines()
        #expect(lines.firstIndex(of: "open \(file)")! < lines.firstIndex(of: "change \(file)")!)

        let hover = await langs.request(ProviderRequest(id: 1, kind: .hover, file: file, line: 1, column: 5), host: nil) { _ in nil }
        #expect(hover == .hover(markdown: "```typescript\nconst x: number\n```"))
        // Diagnostics after edits (debounced), as markers; the unknown event is ignored.
        #expect(await waitUntil { sink.markers.contains { $0.first?.message == "bad (TS1)" } })
        #expect(sink.statuses.contains { $0?.level == .ready || $0?.level == .busy })
        #expect(logLines().filter { $0 == "start" }.count == 1)
        langs.stopAll()
    }

    @Test func definitionOutsideTheProjectIsRefused() async throws {
        let langs = languages()
        let file = dir + "/a.ts"
        langs.opened(file, text: "x", host: nil, owner: owner(Sink()))
        #expect(await waitUntil { logLines().contains("open \(file)") })
        let def = await langs.request(ProviderRequest(id: 2, kind: .definition, file: file, line: 1, column: 1), host: nil) { _ in nil }
        #expect(def == nil)
        langs.stopAll()
    }

    @Test func stopsAfterTheGraceOnceTheLastFileCloses() async throws {
        let langs = languages(grace: .milliseconds(300))
        let a = dir + "/a.ts", id = UUID()
        langs.opened(a, text: "x", host: nil, owner: owner(Sink(), id: id))
        #expect(await waitUntil { langs.runningCount == 1 })
        langs.closed(a, host: nil, owner: id)
        // Reopened within the grace: the same process.
        langs.opened(a, text: "x", host: nil, owner: owner(Sink(), id: id))
        try await Task.sleep(for: .milliseconds(500))
        #expect(langs.runningCount == 1)
        langs.closed(a, host: nil, owner: id)
        #expect(await waitUntil { langs.runningCount == 0 })
        #expect(await waitUntil { logLines().contains("exit ") })
        #expect(logLines().filter { $0 == "start" }.count == 1)
    }

    @Test func restartsOnceAfterACrash() async throws {
        let langs = languages()
        let sink = Sink()
        let file = dir + "/crash.ts"
        langs.opened(file, text: "x", host: nil, owner: owner(sink))
        // First process dies on `open`; the restart reopens the file and stays up.
        #expect(await waitUntil { logLines().filter { $0 == "open \(file)" }.count == 2 })
        #expect(logLines().filter { $0 == "start" }.count == 2)
        #expect(langs.runningCount == 1)
        langs.stopAll()
    }

    @Test func secondCrashStopsWithAStatusAndRestartActionTriesAgain() async throws {
        let langs = languages(mode: "always")
        let sink = Sink()
        let file = dir + "/crash.ts", id = UUID()
        langs.opened(file, text: "x", host: nil, owner: owner(sink, id: id))
        #expect(await waitUntil { sink.statuses.last??.level == .off })
        try await Task.sleep(for: .milliseconds(200))
        #expect(logLines().filter { $0 == "start" }.count == 2)
        langs.restart(file, host: nil)
        #expect(await waitUntil { logLines().filter { $0 == "start" }.count >= 3 })
        langs.stopAll()
    }

    @Test func missingTypeScriptIsACalmStatus() async throws {
        let langs = languages(lookup: .noTypeScript)
        let sink = Sink()
        langs.opened(dir + "/a.ts", text: "x", host: nil, owner: owner(sink))
        #expect(await waitUntil { !sink.statuses.isEmpty })
        #expect(sink.statuses.last??.level == .off)
        #expect(sink.statuses.last??.text == L10n.tsNoTypeScript)
        #expect(logLines().isEmpty)
        #expect(await langs.request(ProviderRequest(id: 3, kind: .hover, file: dir + "/a.ts", line: 1, column: 1), host: nil) { _ in nil } == nil)
    }
}
