#if DEBUG
import AppKit
import WebKit

/// Debug hooks of the Monaco editor and diff (#80): snapshots (the window with the page drawn in), page scripts, state.
extension MainWindowController {
    /// true when `command` was an editor one.
    func debugEditor(_ command: String, _ arg: String) -> Bool {
        let page = column.terminalArea.debugMonaco
        switch command {
        case "edjs": page?.run(arg)  // edjs <script>: run in the shown page (type, find, …)
        case "edfind":
            // edfind <text>: the find widget open with that text.
            let q = (try? JSONSerialization.data(withJSONObject: [arg])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
            page?.run("""
            (function(){ const e = monaco.editor.getEditors().find(x => !x.getOption(monaco.editor.EditorOption.readOnly)) || monaco.editor.getEditors()[0];
              e.focus(); const f = e.getContribution('editor.contrib.findController');
              f.start({ forceRevealReplace: false, seedSearchStringFromSelection: 'none', shouldFocus: 1, shouldAnimate: false, updateSearchScope: false, loop: true });
              f.getState().change({ searchString: \(q)[0] }, true); })()
            """)
        case "edtype":
            // edtype <text>: typed at the cursor of the editable editor (makes it dirty).
            let t = (try? JSONSerialization.data(withJSONObject: [arg])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
            page?.run("""
            (function(){ const e = monaco.editor.getEditors().find(x => !x.getOption(monaco.editor.EditorOption.readOnly));
              if (e) { e.focus(); e.trigger('debug', 'type', { text: \(t)[0] }); } })()
            """)
        case "eddiff": app.openDiff(path: arg)  // eddiff <path from the session folder>: as a Changes click
        case "edinline": app.perform { $0.diffInline = arg == "on" }; column.terminalArea.debugDiffEditor?.setInline(arg == "on")
        case "edfocus": if let page { window?.makeFirstResponder(page.webView) }
        case "edsnap": snapEditor(to: arg)
        case "edstate":
            // edstate <file>: each editor leaf's files (active *, dirty, conflict) and the diff mode.
            let lines = column.terminalArea.debugEditors() + ["diffInline=\(app.state.diffInline) minimap=\(app.state.editorMinimap) responder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-")"]
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        default: return false
        }
        return true
    }

    /// The window as `snap` draws it, with the WKWebView's own snapshot painted over its frame (web content is drawn
    /// out of process, `cacheDisplay` leaves it blank).
    private func snapEditor(to path: String) {
        guard let page = column.terminalArea.debugMonaco, let content = window?.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let frame = page.webView.convert(page.webView.bounds, to: content)
        page.webView.takeSnapshot(with: nil) { image, error in
            MainActor.assumeIsolated {
                guard let image else { uiLog.error("edsnap: \(String(describing: error), privacy: .public)"); return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let y = content.isFlipped ? content.bounds.height - frame.maxY : frame.minY
                image.draw(in: NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                uiLog.info("edsnap \(path, privacy: .public)")
            }
        }
    }
}
#endif
