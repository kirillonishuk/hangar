import Foundation
import Testing
@testable import Workspace

/// The visible text: SGR sequences dropped.
private func plain(_ s: String) -> String { ansiSpans(s).map(\.text).joined() }

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func input(_ json: String) -> StatuslineInput { StatuslineInput(json: Data(json.utf8)) }

private let full = """
{"model":{"id":"claude-opus-5-5","display_name":"Opus"},
 "context_window":{"used_percentage":38,"context_window_size":200000},
 "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":\(1_800_000_000 + 107 * 60)},
                "seven_day":{"used_percentage":18,"resets_at":\(1_800_000_000 + 3 * 86_400)}},
 "effort":{"level":"medium"},"fast_mode":false,"worktree":{"branch":"feat/login"},"cost":{"total_cost_usd":0.04}}
"""

@Suite struct StatuslineTests {
    /// #110: the line is English whatever Hangar's language; the renderer has no language to take.
    @Test func defaultLineIsEnglish() {
        let en = renderStatusline(input(full), segments: StatuslineSegment.defaults, now: now)
        #expect(plain(en) == "Opus 5.5 │ ctx ━━━───── 38% │ 5h ━━━───── 42% 1h47m │ wk 18%")
        #expect(plain(en).count <= 60)
        #expect(!en.contains("$") && !en.contains("0.04") && !en.contains("\n"))
    }

    @Test func missingDataLeavesSegmentsOut() {
        // Before the first reply: no rate limits, no context percentage yet.
        let early = renderStatusline(input(#"{"model":{"display_name":"Sonnet 4.6"},"context_window":{"used_percentage":null}}"#),
                                     segments: StatuslineSegment.defaults, now: now)
        #expect(plain(early) == "Sonnet 4.6")
        #expect(renderStatusline(input("{}"), segments: StatuslineSegment.defaults, now: now) == "")
        #expect(renderStatusline(input("not json"), segments: StatuslineSegment.defaults, now: now) == "")
        // A reset in the past is dropped, the percentage stays.
        let past = renderStatusline(input(#"{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1}}}"#),
                                    segments: [.fiveHour], now: now)
        #expect(plain(past) == "5h ━─────── 5%")
    }

    /// #110: segments come in the configured order; effort chosen is a part of its own, in its place.
    @Test func segmentsInConfiguredOrder() {
        let line = renderStatusline(input(full), segments: [.branch, .week, .model], now: now)
        #expect(plain(line) == "⎇ feat/login │ wk 18% │ Opus 5.5")
        #expect(plain(renderStatusline(input(full), segments: [.fiveHour, .context], now: now))
                == "5h ━━━───── 42% 1h47m │ ctx ━━━───── 38%")
        #expect(plain(renderStatusline(input(full), segments: [.model, .effort], now: now)) == "Opus 5.5 │ effort medium")
        #expect(plain(renderStatusline(input(full), segments: [.effort, .week], now: now)) == "effort medium │ wk 18%")
        // A high level without the effort part stays a marker of the model; with it, it is not shown twice.
        let high = #"{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"}}"#
        #expect(plain(renderStatusline(input(high), segments: [.model], now: now)) == "Opus 5.5 high")
        #expect(plain(renderStatusline(input(high), segments: [.effort, .model], now: now)) == "effort high │ Opus 5.5")
    }

    @Test func modelMarkers() {
        let json = #"{"model":{"id":"claude-opus-4-7[1m]","display_name":"Opus 4.7 (1M context)"},"context_window":{"context_window_size":1000000,"used_percentage":12.4},"fast_mode":true,"effort":{"level":"high"}}"#
        let line = renderStatusline(input(json), segments: StatuslineSegment.defaults, now: now)
        #expect(plain(line) == "Opus 4.7 1M fast high │ ctx ━─────── 12%")
        #expect(line.contains("\u{1B}[2m1M\u{1B}[0m"))
        #expect(shortModelName(display: "Claude Sonnet 4.5", id: nil) == "Sonnet 4.5")
        #expect(shortModelName(display: "Haiku", id: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(shortModelName(display: nil, id: "claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(shortModelName(display: "", id: "") == nil)
        #expect(shortModelName(display: "Evil\u{1B}[31m\nname", id: nil) == "Evil[31mname")
    }

    @Test func thresholdsColour() {
        func five(_ p: Double) -> String {
            renderStatusline(input(#"{"rate_limits":{"five_hour":{"used_percentage":\#(p)}}}"#), segments: [.fiveHour], now: now)
        }
        #expect(!five(79.4).contains("\u{1B}[33m") && !five(79.4).contains("\u{1B}[31m"))
        #expect(five(80).contains("\u{1B}[33m80%\u{1B}[0m"))
        #expect(five(95).contains("\u{1B}[31m95%\u{1B}[0m") && five(95).contains("\u{1B}[31m━━━━━━━━\u{1B}[0m"))
        #expect(plain(five(100)) == "5h ━━━━━━━━ 100%")
        #expect(plain(five(0)) == "5h ──────── 0%")
        #expect(ansiSpans(five(50)).first == AnsiSpan("5h", .dim))
    }

    @Test func weekResetOnlyNearLimit() {
        let json = #"{"rate_limits":{"seven_day":{"used_percentage":83,"resets_at":\#(1_800_000_000 + 2 * 86_400 + 3 * 3600)}}}"#
        #expect(plain(renderStatusline(input(json), segments: [.week], now: now)) == "wk 83% 2d3h")
    }

    @Test func durations() {
        #expect(compactDuration(10) == "1m")
        #expect(compactDuration(47 * 60) == "47m")
        #expect(compactDuration(107 * 60) == "1h47m")
        #expect(compactDuration(2 * 3600) == "2h")
        #expect(compactDuration(2 * 86_400 + 3 * 3600) == "2d3h")
        #expect(compactDuration(3 * 86_400) == "3d")
    }

    @Test func ansiSpansForPreview() {
        #expect(ansiSpans("a\u{1B}[2mb\u{1B}[0m\u{1B}[33mc\u{1B}[0md\u{1B}[31me") ==
                [AnsiSpan("a", .normal), AnsiSpan("b", .dim), AnsiSpan("c", .yellow), AnsiSpan("d", .normal), AnsiSpan("e", .red)])
        #expect(ansiSpans("x\u{1B}[1Ay\u{1B}") == [AnsiSpan("xy", .normal)])
        let sample = renderStatusline(.sample(now: now), segments: StatuslineSegment.defaults, now: now)
        #expect(plain(sample) == "Opus 5.5 │ ctx ━━━───── 38% │ 5h ━━━━━━━─ 84% 1h47m │ wk 31%")
        #expect(ansiSpans(sample).contains(AnsiSpan("84%", .yellow)))
    }
}
