import Foundation
@testable import Git
import Testing
@testable import HangarUI

@Suite struct SyntaxTests {
    /// Non-plain tokens of `lines` (state carried line to line) as `k:func`, `s:"a"`, `c:// x`, `n:1`, `t:Int`.
    private func lex(_ path: String, _ lines: [String]) -> [String] {
        guard let lang = syntaxLanguage(forPath: path) else { return ["no language"] }
        var state = SyntaxState.normal
        return lines.flatMap { line -> [String] in
            let bytes = Array(line.utf8)
            return highlightLine(line, lang, &state).map { span in
                let code = switch span.kind {
                case .keyword: "k"
                case .string: "s"
                case .comment: "c"
                case .number: "n"
                case .type: "t"
                }
                return code + ":" + String(decoding: bytes[span.range], as: UTF8.self)
            }
        }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        let lines: [String]
        let tokens: [String]
        var testDescription: String { path + " " + lines.joined(separator: "⏎") }
    }

    static let cases: [Case] = [
        // Swift
        .init(path: "a.swift", lines: ["let x: Int = 42 // answer"], tokens: ["k:let", "t:Int", "n:42", "c:// answer"]),
        .init(path: "a.swift", lines: [#"let s = "a \"b\" c""#], tokens: ["k:let", #"s:"a \"b\" c""#]),
        .init(path: "a.swift", lines: ["/* one", "two */ func f() {}"], tokens: ["c:/* one", "c:two */", "k:func"]),
        .init(path: "a.swift", lines: [#"let s = """"#, #"  text "quoted""#, #"  """ + x"#],
              tokens: ["k:let", #"s:""""#, #"s:  text "quoted""#, #"s:  """"#]),
        .init(path: "a.swift", lines: ["x1 = 0x1F + 1.5"], tokens: ["n:0x1F", "n:1.5"]),
        // JS / TS / TSX / JSX
        .init(path: "a.ts", lines: ["const a: Foo = 'x\\'y'; // c"], tokens: ["k:const", "t:Foo", "s:'x\\'y'", "c:// c"]),
        .init(path: "a.tsx", lines: ["return `a", "b ${c}` + 1"], tokens: ["k:return", "s:`a", "s:b ${c}`", "n:1"]),
        .init(path: "a.jsx", lines: ["/**", " * doc", " */ export default x"],
              tokens: ["c:/**", "c: * doc", "c: */", "k:export", "k:default"]),
        .init(path: "a.mjs", lines: ["if (x) null"], tokens: ["k:if", "k:null"]),
        // Python
        .init(path: "a.py", lines: ["def f(x): # c", "    return None"], tokens: ["k:def", "c:# c", "k:return", "k:None"]),
        .init(path: "a.py", lines: [#"s = """doc"#, #"more "x" """ + 'a\'b'"#],
              tokens: [#"s:"""doc"#, #"s:more "x" """"#, #"s:'a\'b'"#]),
        // Go
        .init(path: "a.go", lines: ["func main() { x := `raw", "\\` + 'a'"], tokens: ["k:func", "s:`raw", "s:\\`", "s:'a'"]),
        // Rust: a lifetime is not a char literal.
        .init(path: "a.rs", lines: ["fn f<'a>(x: &'a str) -> Vec<u8> { 'c' }"], tokens: ["k:fn", "t:Vec", "s:'c'"]),
        .init(path: "a.rs", lines: [#"let c = '\''; // q"#], tokens: ["k:let", #"s:'\''"#, "c:// q"]),
        // Kotlin / Java
        .init(path: "A.kt", lines: ["val s = \"\"\"a", "b\"\"\" // end"], tokens: ["k:val", "s:\"\"\"a", "s:b\"\"\"", "c:// end"]),
        .init(path: "A.java", lines: ["public class A extends B {}"], tokens: ["k:public", "k:class", "t:A", "k:extends", "t:B"]),
        // C / C++ / ObjC
        .init(path: "a.h", lines: ["#include <stdio.h>", "int x = 'a'; /* c"], tokens: ["k:include", "k:int", "s:'a'", "c:/* c"]),
        .init(path: "a.m", lines: [#"@interface Foo : NSObject"#], tokens: ["k:@interface", "t:Foo", "t:NSObject"]),
        .init(path: "a.cpp", lines: [#"auto s = "x\\"; // y"#], tokens: ["k:auto", #"s:"x\\""#, "c:// y"]),
        // Ruby
        .init(path: "a.rb", lines: ["def f # c", "  puts \"a\\\"b\" end"], tokens: ["k:def", "c:# c", "s:\"a\\\"b\"", "k:end"]),
        // Shell
        .init(path: "a.sh", lines: ["if [ -n \"$x\" ]; then echo 'a#b' # c", "fi"],
              tokens: ["k:if", "s:\"$x\"", "k:then", "s:'a#b'", "c:# c", "k:fi"]),
        .init(path: "a.zsh", lines: ["echo a#b"], tokens: []),
        // JSON
        .init(path: "a.json", lines: [#"{"a": "b\"c", "n": -1.5e3, "t": true}"#],
              tokens: [#"s:"a""#, #"s:"b\"c""#, #"s:"n""#, "n:1.5e3", #"s:"t""#, "k:true"]),
        // YAML / TOML: keys, strings, comments.
        .init(path: "a.yml", lines: ["name: \"x\" # c", "  - key: 'v'", "plain: text"],
              tokens: ["k:name", "s:\"x\"", "c:# c", "k:key", "s:'v'", "k:plain"]),
        .init(path: "a.toml", lines: ["[deps]", "serde = \"1.0\" # c"], tokens: ["t:[deps]", "k:serde", "s:\"1.0\"", "c:# c"]),
        // CSS
        .init(path: "a.css", lines: ["@media x { a { color: #fff; margin: 4px } } /* c", "*/"],
              tokens: ["k:@media", "k:color", "n:#fff", "k:margin", "n:4px", "c:/* c", "c:*/"]),
        // HTML / XML: tags and attributes.
        .init(path: "a.html", lines: [#"<div class="a" id='b'>text</div> <!-- c"#, "--> <br/>"],
              tokens: ["k:<div", "t:class", #"s:"a""#, "t:id", "s:'b'", "k:>", "k:</div", "k:>", "c:<!-- c", "c:-->", "k:<br", "k:/>"]),
        .init(path: "a.xml", lines: ["<a", "  href=\"x\">"], tokens: ["k:<a", "t:href", "s:\"x\"", "k:>"]),
        // SQL
        .init(path: "a.sql", lines: ["SELECT a FROM t WHERE b = 'it''s' -- c", "/* x */ select 1"],
              tokens: ["k:SELECT", "k:FROM", "k:WHERE", "s:'it''s'", "c:-- c", "c:/* x */", "k:select", "n:1"]),
        // Markdown: headings and code.
        .init(path: "README.md", lines: ["# Title", "text `code` more", "```swift", "let x = 1", "```", "after"],
              tokens: ["k:# Title", "s:`code`", "s:```swift", "s:let x = 1", "s:```"]),
    ]

    @Test(arguments: cases) func tokens(_ c: Case) {
        #expect(lex(c.path, c.lines) == c.tokens)
    }

    @Test func unknownExtensionsStayPlain() {
        #expect(syntaxLanguage(forPath: "notes.txt") == nil)
        #expect(syntaxLanguage(forPath: "Makefile") == nil)
        #expect(syntaxLanguage(forPath: "dir.swift/file") == nil)
        #expect(syntaxLanguage(forPath: "src/App.TSX") != nil)
    }

    @Test func longLinesAreSkippedWithoutTouchingTheState() {
        let lang = syntaxLanguage(forPath: "a.swift")!
        var state = SyntaxState.normal
        _ = highlightLine("/* open", lang, &state)
        let before = state
        #expect(highlightLine("let " + String(repeating: "x", count: 3000), lang, &state).isEmpty)
        #expect(state == before)
    }

    /// The state restarts at each hunk: a comment opened in one hunk doesn't color the next.
    @MainActor @Test func diffHighlightResetsAtHunks() {
        let diff = "diff --git a/f.swift b/f.swift\n--- a/f.swift\n+++ b/f.swift\n@@ -1,1 +1,1 @@\n-/* open\n+let x\n@@ -9,1 +9,1 @@\n let y\n"
        let content = DiffContentCache().content(.loaded(parseUnifiedDiff(diff)), origPath: nil, path: "f.swift")
        let kinds = { (i: Int) in content.highlighter?.spans(at: i).map(\.kind) }
        #expect(kinds(1) == [.comment])
        // The added line follows the deleted one on its own side: `/*` is only on the old side.
        #expect(kinds(2) == [.keyword])
        #expect(kinds(4) == [.keyword])
        // Out of order (a jump while scrolling): the row is lexed from its hunk start.
        let fresh = DiffContentCache().content(.loaded(parseUnifiedDiff(diff)), origPath: nil, path: "f.swift").highlighter
        #expect(fresh?.spans(at: 2).map(\.kind) == [.keyword])
        #expect(fresh?.spans(at: 1).map(\.kind) == [.comment])
        #expect(DiffContentCache().content(.loaded(parseUnifiedDiff(diff)), origPath: nil, path: "f.txt").highlighter == nil)
    }
}
