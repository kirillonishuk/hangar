import AppKit
import Git
import SwiftUI

/// The commit log: 28 pt rows, the graph drawn per row in a Canvas, the next page asked for near the end.
struct GitLogList: View {
    let app: AppState
    let model: GitPanelModel

    var body: some View {
        let commits = model.commits
        let graph = model.graph
        let head = model.branches?.head.branch
        let mark = model.query.text.trimmingCharacters(in: .whitespaces)
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(commits.enumerated()), id: \.element.hash) { i, c in
                    GitLogRow(commit: c, graph: graph.indices.contains(i) ? graph[i] : nil, head: head,
                              mark: mark, now: model.loadedAt, selected: model.selected == c.hash) {
                        model.select(model.selected == c.hash ? nil : c.hash)
                    }
                    .equatable()
                    .onAppear { if i >= commits.count - 20 { model.loadMore() } }
                }
            }
            .padding(.vertical, Theme.fileRowPaddingV)
        }
        .frame(maxHeight: .infinity)
    }
}

/// One commit: graph, ref chips, subject, date; hash, author and the full date in the tooltip (mockup).
/// The graph cell is as wide as this row's lanes, the subject starts right after it; chips never push out the
/// subject (it keeps `subjectMin`) or the date (its own column, never clipped).
struct GitLogRow: View, Equatable {
    let commit: Commit
    /// nil: the graph is hidden (narrowing filters), only a dot.
    let graph: GraphRow?
    /// The checked-out branch: its chip is `accent`.
    let head: String?
    let mark: String
    let now: Date
    let selected: Bool
    let action: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.commit == b.commit && a.graph == b.graph && a.head == b.head && a.mark == b.mark
            && a.now == b.now && a.selected == b.selected
    }

    var body: some View {
        let chips = refChips(commit.refs, limit: Theme.GitTab.maxRefs)
        GitRow(selected: selected, action: action) {
            HStack(spacing: Theme.GitTab.rowGap) {
                GitGraphCell(row: graph, isMerge: commit.parents.count > 1, background: selected ? Theme.ui.selected : Theme.ui.bg1)
                    .frame(width: graphWidth(graph), height: Theme.GitTab.logRow)
                if !chips.shown.isEmpty {
                    HStack(spacing: Theme.GitTab.refGap) {
                        ForEach(Array(chips.shown.enumerated()), id: \.offset) { _, chip in
                            GitRefPill(ref: chip.ref, lane: graph?.color ?? 0, head: head, twin: chip.twin, maxWidth: Theme.GitTab.refMaxWidth)
                        }
                        if chips.more > 0 { GitMoreRefs(count: chips.more) }
                    }
                    .layoutPriority(1)
                }
                subject
                    .font(.system(size: Theme.fontSize.row))
                    .foregroundStyle(selected ? Theme.ui.text0 : commit.parents.count > 1 ? Theme.ui.text2 : Theme.ui.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: Theme.GitTab.subjectMin, maxWidth: .infinity, alignment: .leading)
                Text(gitShortDate(commit.date, now: now))
                    .font(.system(size: Theme.GitTab.mono, design: .monospaced))
                    .foregroundStyle(selected ? Theme.ui.text2 : Theme.ui.text3)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: GitRefPill.dateColumn, alignment: .trailing)
                    .layoutPriority(2)
            }
            .padding(.trailing, Theme.GitTab.chipLeading)
            .frame(height: Theme.GitTab.logRow)
        }
        .popoverContextMenu { [hash = commit.hash] in
            [.item(PopoverMenuItem(title: L10n.gitCopyHash, icon: .copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hash, forType: .string)
            })]
        }
        .help(tooltip)
    }

    /// Search hits marked in `waiting` 28 % (a hash search finds the commit, not text).
    private var subject: Text {
        guard !mark.isEmpty else { return Text(verbatim: commit.subject) }
        var s = AttributedString(commit.subject)
        var from = s.startIndex
        while from < s.endIndex, let r = s[from...].range(of: mark, options: [.caseInsensitive, .diacriticInsensitive]) {
            s[r].backgroundColor = Theme.ui.waiting.opacity(Theme.Opacity.fill)
            s[r].foregroundColor = Theme.ui.text0
            from = r.upperBound
        }
        return Text(s)
    }

    private var tooltip: String {
        let refs = commit.refs.map(\.name).joined(separator: ", ")
        return [String(commit.hash.prefix(7)) + " · " + commit.authorName + " · " + gitLongDate(commit.date, now: now), refs, commit.subject]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A ref chip 18: own branch `accent` 14 %, remote `text2` 14 %, other branches and tags their lane's colour 16 %.
struct GitRefPill: View {
    let ref: CommitRef
    let lane: Int
    let head: String?
    /// Its remote twin (`origin/<name>`) points here too: one chip with a `⇅` mark.
    var twin: String? = nil
    var maxWidth = Theme.GitTab.chipMaxWidth

    var body: some View {
        let tint: Color, opacity: Double
        switch ref.kind {
        case .head: (tint, opacity) = (Theme.ui.accentText, Theme.Opacity.fill)
        case .branch where ref.isHead || ref.name == head: (tint, opacity) = (Theme.ui.accentText, Theme.Opacity.fill)
        case .remote: (tint, opacity) = (Theme.ui.text2, Theme.Opacity.fill)
        case .branch, .tag: (tint, opacity) = (Theme.GitTab.lane(lane), Theme.Opacity.fill)
        }
        return HStack(spacing: Theme.GitTab.refMarkGap) {
            Text(verbatim: ref.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if twin != nil { Text(verbatim: Self.syncedMark).fixedSize() }
        }
        .font(.system(size: Theme.GitTab.mono, design: .monospaced))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.GitTab.refPaddingH)
        .frame(height: Theme.GitTab.refHeight)
        .background(RoundedRectangle(cornerRadius: Theme.GitTab.refRadius).fill(tint.opacity(opacity)))
        // Its own width up to the cap; in a tight row it gives way down to `refMinWidth` (a maxWidth frame alone
        // would grow to the cap).
        .frame(minWidth: min(Self.width(label), Theme.GitTab.refMinWidth), idealWidth: min(Self.width(label), maxWidth),
               maxWidth: min(Self.width(label), maxWidth), alignment: .leading)
        .help(twin.map { ref.name + " · " + $0 } ?? ref.name)
    }

    private var label: String { twin != nil ? ref.name + " " + Self.syncedMark : ref.name }
    static let syncedMark = "⇅"

    private static let font = NSFont.monospacedSystemFont(ofSize: Theme.GitTab.mono, weight: .regular)

    static func width(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: font]).width) + Theme.GitTab.refPaddingH * 2
    }

    /// The date column: «00:00», «23 окт» and «вчера» end on one line; an older year's date may be wider.
    @MainActor static var dateColumn: CGFloat {
        ["000000", L10n.gitYesterday].map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
    }
}

/// «+k»: refs past the row's chips (all of them are in the row's tooltip).
struct GitMoreRefs: View {
    let count: Int

    var body: some View {
        Text(verbatim: "+\(count)")
            .font(.system(size: Theme.GitTab.mono, design: .monospaced))
            .foregroundStyle(Theme.ui.text2)
            .padding(.horizontal, Theme.GitTab.refPaddingH)
            .frame(height: Theme.GitTab.refHeight)
            .background(RoundedRectangle(cornerRadius: Theme.GitTab.refRadius).fill(Theme.ui.text2.opacity(Theme.Opacity.fill)))
            .fixedSize()
    }
}

/// A row's graph cell: as wide as the lanes it draws (one lane → 20), clipped to `maxLanes`.
func graphWidth(_ row: GraphRow?) -> CGFloat {
    let lanes = min(max(row?.width ?? 1, 1), Theme.GitTab.maxLanes)
    return Theme.GitTab.laneX0 * 2 + CGFloat(lanes - 1) * Theme.GitTab.laneStep
}

/// A ref chip of a log row: a local branch absorbs its remote twin pointing at the same commit (`twin`).
struct RefChip: Equatable {
    var ref: CommitRef
    var twin: String? = nil
}

/// The chips a row shows, in git's order, and how many more there are («+k»): at most `limit` items in all, so
/// past it the last place is the «+k».
func refChips(_ refs: [CommitRef], limit: Int) -> (shown: [RefChip], more: Int) {
    let locals = Set(refs.filter { $0.kind == .branch }.map(\.name))
    func localTwin(_ r: CommitRef) -> String? {
        guard r.kind == .remote, let slash = r.name.firstIndex(of: "/") else { return nil }
        let name = String(r.name[r.name.index(after: slash)...])
        return locals.contains(name) ? name : nil
    }
    var twins: [String: String] = [:]
    for r in refs { if let name = localTwin(r), twins[name] == nil { twins[name] = r.name } }
    let chips = refs.filter { localTwin($0) == nil }.map { RefChip(ref: $0, twin: $0.kind == .branch ? twins[$0.name] : nil) }
    let room = chips.count > limit ? max(limit - 1, 0) : chips.count
    return (Array(chips.prefix(room)), chips.count - room)
}

/// The rails and the dot of one row (lanes every 12 from x 10, dot r 4 with a 2 pt ring of the row's background,
/// merge = ring r 3.5). Bends sit in the lower half (`layoutGraph`): from the dot it leaves sideways, as the mockup.
struct GitGraphCell: View {
    let row: GraphRow?
    let isMerge: Bool
    let background: Color

    var body: some View {
        Canvas { ctx, size in
            let t = Theme.GitTab.self
            let mid = size.height / 2, bottom = size.height
            func x(_ lane: Int) -> CGFloat { t.laneX0 + CGFloat(lane) * t.laneStep }
            let visible = 0..<t.maxLanes
            guard let row else {
                dot(&ctx, at: CGPoint(x: x(0), y: mid), color: t.lane(0))
                return
            }
            for s in row.segments where visible.contains(s.from) && visible.contains(s.to) {
                var p = Path()
                switch s.half {
                case .upper:
                    p.move(to: CGPoint(x: x(s.from), y: 0))
                    p.addLine(to: CGPoint(x: x(s.to), y: mid))
                case .lower:
                    let a = CGPoint(x: x(s.from), y: mid), b = CGPoint(x: x(s.to), y: bottom)
                    p.move(to: a)
                    if s.from == s.to {
                        p.addLine(to: b)
                    } else if s.from == row.lane {
                        p.addQuadCurve(to: b, control: CGPoint(x: b.x, y: mid))
                    } else {
                        let m = (mid + bottom) / 2
                        p.addCurve(to: b, control1: CGPoint(x: a.x, y: m), control2: CGPoint(x: b.x, y: m))
                    }
                }
                ctx.stroke(p, with: .color(t.lane(s.color)), style: StrokeStyle(lineWidth: t.rail, lineCap: .round))
            }
            if visible.contains(row.lane) { dot(&ctx, at: CGPoint(x: x(row.lane), y: mid), color: t.lane(row.color)) }
        }
        .allowsHitTesting(false)
    }

    private func dot(_ ctx: inout GraphicsContext, at c: CGPoint, color: Color) {
        let t = Theme.GitTab.self
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        if isMerge {
            ctx.fill(circle(t.mergeRing), with: .color(background))
            ctx.stroke(circle(t.mergeRing), with: .color(color), lineWidth: t.rail)
        } else {
            ctx.fill(circle(t.dot + t.dotRing), with: .color(background))
            ctx.fill(circle(t.dot), with: .color(color))
        }
    }
}
