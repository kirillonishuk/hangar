#if DEBUG
import AppKit
import Git

/// `git …` debug commands: drive the Git tab for verification runs without a screen (not compiled in release).
extension MainWindowController {
    func debugGit(_ arg: String) {
        let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = f.count > 1 ? f[1] : ""
        let m = app.gitPanel
        switch f.first ?? "" {
        case "select": if let n = Int(rest), m.commits.indices.contains(n) { m.select(m.commits[n].hash) } else { m.select(nil) }
        case "text": m.query.text = rest
        case "author": m.query.author = Int(rest).flatMap { m.authors.indices.contains($0) ? m.authors[$0].author : nil }
        case "date": m.query.date = ["today": .today, "week": .week, "month": .month][rest]
        case "path": m.query.path = rest.isEmpty ? nil : rest
        case "scope": m.query.scope = rest == "all" ? .all : rest == "head" ? .head : .ref(rest)
        case "branches": m.branchesOpen.toggle()
        case "expand": m.expanded.insert(rest)
        case "file":
            if let d = m.details, let n = Int(rest) {
                let files = commitFileGroups(d.files).flatMap(\.files)
                if files.indices.contains(n) { app.openCommitDiff(hash: d.commit.hash, file: files[n]) }
            }
        case "size":  // size <w> <h>: the window's content size (the short-window layout)
            let v = rest.split(separator: " ").compactMap { Double($0) }
            if v.count == 2 { window?.setContentSize(NSSize(width: v[0], height: v[1])) }
        case "width":  // width <n>: the inspector's width, as a divider drag would leave it
            if let w = Double(rest) {
                let view = split.splitView
                view.setPosition(view.bounds.width - w - view.dividerThickness, ofDividerAt: 1)
            }
        case "scrollEnd":  // the log scrolled to its end, as a user's scroll (row onAppear pages in more)
            func scrollViews(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
            let views = scrollViews(inspectorItem.viewController.view)
            if let s = views.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }), let doc = s.documentView {
                let y = doc.isFlipped ? max(0, doc.frame.height - s.contentView.bounds.height) : 0
                s.contentView.scroll(to: NSPoint(x: 0, y: y))
                s.reflectScrolledClipView(s.contentView)
            }
        case "dump":  // dump <file>: the model's state as text
            let s = "commits=\(m.commits.map(\.subject)) graph=\(m.graph.count) shows=\(m.showsGraph) query=\(m.query) hides=\(m.query.hidesGraph)\n"
            try? s.write(toFile: rest, atomically: true, encoding: .utf8)
        default: break
        }
        uiLog.info("git panel visible=\(m.visible) commits=\(m.commits.count) more=\(m.hasMore) graph=\(m.graph.count) selected=\(m.selected ?? "-", privacy: .public) files=\(m.details?.files.count ?? -1) diff=\(m.commitDiff.map { "\($0.path) \($0.state == .loading ? "loading" : "done")" } ?? "-", privacy: .public) error=\(m.error ?? "-", privacy: .public)")
    }
}
#endif
