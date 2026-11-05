import AppKit
import Git
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Files the diff tab's «Просмотр» renders (HD-151), by extension.
enum RenderKind: Equatable {
    case html, markdown, svg

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm", "xhtml": self = .html
        case "md", "markdown": self = .markdown
        case "svg": self = .svg
        default: return nil
        }
    }

    /// Bigger sides keep the notice: a review preview, not a browser.
    static let maxBytes = 5 << 20
}

/// «Просмотр» is offered: a text diff of an HTML / Markdown / SVG file of a project on this Mac.
func previewEligible(path: String, isText: Bool, local: Bool) -> Bool {
    // shortcut: a server's project has no toggle — its runner has no byte channel (as HD-142); add one when asked for.
    local && isText && RenderKind(path: path) != nil
}

/// What the web view loads for one side: the HTML as is; Markdown as a themed page; SVG as an `<img>` (never a
/// document of its own, so it loads nothing and runs nothing even without the page's limits).
@MainActor func renderedPage(_ data: Data, kind: RenderKind) -> Data {
    switch kind {
    case .html: return data
    case .svg:
        let src = "data:image/svg+xml;base64," + data.base64EncodedString()
        let p = Theme.palette
        return Data(("<!doctype html><meta charset=utf-8><style>html,body{margin:0;height:100%;background:\(p.bg0.css)}"
            + "body{display:flex;align-items:center;justify-content:center}img{max-width:100%;max-height:100%}</style>"
            + "<img src=\"\(src)\">").utf8)
    case .markdown:
        let p = Theme.palette, body = Theme.Typography.body, mono = Theme.Typography.mono
        let css = "html{color-scheme:light dark}body{margin:0;padding:\(Int(Theme.Space.s4))px;background:\(p.bg0.css);color:\(p.text1.css);"
            + "font:\(Int(body.size))px/\(Int(body.lineHeight))px -apple-system,system-ui}"
            + "h1,h2,h3,h4,h5,h6{color:\(p.text0.css)}a{color:\(p.accentText.css)}"
            + "code,pre{font-family:ui-monospace,'SF Mono',monospace;font-size:\(Int(mono.size))px}"
            + "pre{background:\(p.bg1.css);padding:\(Int(Theme.Space.s2))px;border-radius:\(Int(Theme.Radius.control))px;overflow:auto}"
            + "blockquote{margin-left:0;padding-left:\(Int(Theme.Space.s3))px;border-left:2px solid \(p.line2.css);color:\(p.text2.css)}"
            + "table{border-collapse:collapse}td{border:1px solid \(p.line2.css);padding:\(Int(Theme.Space.s1))px \(Int(Theme.Space.s2))px}"
            + "thead td{font-weight:600}hr{border:0;border-top:1px solid \(p.line2.css)}img{max-width:100%}"
        return Data(("<!doctype html><meta charset=utf-8><style>\(css)</style>"
            + markdownHTML(String(decoding: data, as: UTF8.self))).utf8)
    }
}

private func escapeHTML(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(c)
        }
    }
    return out
}

/// Markdown → HTML through the system parser (`AttributedString(markdown:)`, GitHub-flavoured), block intents turned
/// back into tags. Raw HTML in the source stays text: the page never gets markup the file didn't spell as Markdown.
func markdownHTML(_ source: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                          failurePolicy: .returnPartiallyParsedIfPossible)
    guard let text = try? AttributedString(markdown: source, options: options) else { return "<pre>\(escapeHTML(source))</pre>" }
    var html = ""
    var open: [PresentationIntent.IntentType] = []  // outermost first
    func tag(_ c: PresentationIntent.IntentType, closing: Bool) -> String {
        let s = closing ? "/" : ""
        switch c.kind {
        case .paragraph: return "<\(s)p>"
        case .header(let level): return "<\(s)h\(min(max(level, 1), 6))>"
        case .orderedList: return "<\(s)ol>"
        case .unorderedList: return "<\(s)ul>"
        case .listItem: return "<\(s)li>"
        case .codeBlock: return closing ? "</code></pre>" : "<pre><code>"
        case .blockQuote: return "<\(s)blockquote>"
        case .thematicBreak: return closing ? "" : "<hr>"
        case .table: return "<\(s)table>"
        case .tableHeaderRow: return closing ? "</tr></thead>" : "<thead><tr>"
        case .tableRow: return "<\(s)tr>"
        case .tableCell: return "<\(s)td>"
        @unknown default: return ""
        }
    }
    for run in text.runs {
        let stack = Array((run.presentationIntent?.components ?? []).reversed())
        var common = 0
        while common < open.count, common < stack.count, open[common].identity == stack[common].identity { common += 1 }
        for c in open[common...].reversed() { html += tag(c, closing: true) }
        for c in stack[common...] { html += tag(c, closing: false) }
        open = stack
        let raw = String(text[run.range].characters)
        if stack.contains(where: { if case .thematicBreak = $0.kind { true } else { false } }) { continue }
        if stack.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) { html += escapeHTML(raw); continue }
        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.softBreak) { html += "\n"; continue }
        if inline.contains(.lineBreak) { html += "<br>"; continue }
        if let image = run.imageURL {
            html += "<img src=\"\(escapeHTML(image.relativeString))\" alt=\"\(escapeHTML(raw))\">"
            continue
        }
        var piece = escapeHTML(raw)
        if inline.contains(.code) { piece = "<code>\(piece)</code>" }
        if inline.contains(.emphasized) { piece = "<em>\(piece)</em>" }
        if inline.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
        if inline.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
        if let link = run.link { piece = "<a href=\"\(escapeHTML(link.relativeString))\">\(piece)</a>" }
        html += piece
    }
    for c in open.reversed() { html += tag(c, closing: true) }
    return html
}

/// The pages' own scheme: `hangar-preview://page/<folder>/` is the file's folder, so `common.css` or `img/a.png` next to
/// the file load — through the handler, from inside the project only; the page gets no file:// access at all.
let previewScheme = "hangar-preview"

/// The file a page asks for, inside `root` after resolving links; nil for anything else (`..`, a link out of the project).
func previewAssetPath(_ url: URL, root: String) -> String? {
    guard url.scheme == previewScheme, url.host == "page" else { return nil }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains("\0") }) else { return nil }
    let base = (root as NSString).resolvingSymlinksInPath
    let path = ((base + "/" + parts.joined(separator: "/")) as NSString).resolvingSymlinksInPath
    return path.hasPrefix(base + "/") ? path : nil
}

/// The base URL of a page of `dir` (relative to the project root).
func previewBase(dir: String) -> URL {
    var c = URLComponents()
    c.scheme = previewScheme
    c.host = "page"
    c.path = "/" + (dir.isEmpty ? "" : dir + "/")
    return c.url ?? URL(string: "\(previewScheme)://page/")!
}

private final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The shown file's project root (main thread only: WebKit calls the handler there).
    var root: String?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let root, let path = previewAssetPath(url, root: root),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
              size <= RenderKind.maxBytes, let data = FileManager.default.contents(atPath: path) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// One rendered side (HD-151): JavaScript off, no network (the editor's rule list), a non-persistent store; only the
/// load Hangar starts is allowed — a clicked http(s) link opens in the default browser, any other navigation is dropped.
@MainActor final class RenderedPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let assets = PreviewSchemeHandler()
    private var shown: (page: Data, root: String, dir: String)?
    /// The next main-frame navigation is Hangar's own `load`.
    private var ownLoad = false

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assets, forURLScheme: previewScheme)
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        #if DEBUG
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if ProcessInfo.processInfo.environment["HANGAR_DEBUG_NO_ACTIVATE"] != nil, webView.responds(to: occlusion) {
            typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: Set.self)(webView, occlusion, false)
        }
        #endif
    }

    /// `dir`: the file's folder under `root`, where its relative links point.
    func show(_ page: Data, root: String, dir: String) {
        if let shown, shown.page == page, shown.root == root, shown.dir == dir { return }
        shown = (page, root, dir)
        assets.root = root
        MonacoPage.withBlockList { [weak self] list in
            // No rule list, no page: the no-network promise holds or nothing is shown.
            guard let self, let list, let shown = self.shown, shown.page == page else { return }
            let controller = self.webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            controller.add(list)
            self.ownLoad = true
            self.webView.load(page, mimeType: "text/html", characterEncodingName: "utf-8", baseURL: previewBase(dir: dir))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        if action.targetFrame?.isMainFrame == true, ownLoad {
            ownLoad = false
            return .allow
        }
        // A frame of the page (`<iframe src="part.html">`): the project's files only, and it runs no script either.
        if let frame = action.targetFrame, !frame.isMainFrame, action.navigationType == .other,
           [previewScheme, "about", "data"].contains(scheme) { return .allow }
        if action.navigationType == .linkActivated, let url, scheme == "http" || scheme == "https" { NSWorkspace.shared.open(url) }
        return .cancel
    }
}

/// The page of one side inside SwiftUI.
private struct RenderedWebView: NSViewRepresentable {
    let page: Data
    let root: String
    let dir: String

    func makeCoordinator() -> RenderedPage { RenderedPage() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.show(page, root: root, dir: dir) }
}

/// The rendered file: one page (added, deleted) or «Было» / «Стало» side by side in a wide pane, one above the other
/// in a narrow one — the layout of the image preview (HD-142).
struct RenderedPreviewView: View {
    struct Side: Identifiable {
        var id: Int
        var title: String?
        var page: Data
    }

    let root: String
    let dir: String
    let sides: [Side]

    var body: some View {
        if sides.count == 1, let side = sides.first {
            // One page (the editor, an added or deleted file): the whole pane, as the code it replaces.
            RenderedWebView(page: side.page, root: root, dir: dir)
        } else {
            pair
        }
    }

    private var pair: some View {
        GeometryReader { geo in
            let layout = geo.size.width >= geo.size.height
                ? AnyLayout(HStackLayout(spacing: Theme.Space.s4)) : AnyLayout(VStackLayout(spacing: Theme.Space.s4))
            layout {
                ForEach(sides) { side in
                    VStack(spacing: Theme.Space.s2) {
                        RenderedWebView(page: side.page, root: root, dir: dir)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.ui.line2))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                        if let title = side.title {
                            Text(verbatim: title).font(Theme.Typography.caption.font(.semibold)).foregroundStyle(Theme.ui.text2)
                        }
                    }
                }
            }
            .padding(Theme.Space.s4)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.ui.bg0)
    }
}

/// «Код · Просмотр» in the diff and editor headers (HD-151): one remembered choice for every HTML / Markdown / SVG file.
struct RenderSwitch: View {
    let app: AppState

    var body: some View {
        Segmented(selection: app.state.renderPreview, options: [
            SegmentOption(value: false, title: L10n.renderCode),
            SegmentOption(value: true, title: L10n.diffPreview, help: L10n.diffPreviewHelp),
        ]) { on in app.perform { $0.renderPreview = on } }
    }
}

/// The editor's rendered file over Monaco (HD-151); `onMouseDown` focuses its pane as the image does.
final class RenderedHostingView: NSHostingView<RenderedPreviewView> {
    var onMouseDown: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }  // takes focus from the Monaco under it

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

/// Where a rendered editor file's relative links may reach: its chat's folder when the file is inside, else its own folder.
func renderRoot(path: String, cwd: String?) -> (root: String, dir: String) {
    let folder = (path as NSString).deletingLastPathComponent
    if let cwd, !cwd.isEmpty, path.hasPrefix(cwd + "/") {
        return (cwd, String(folder.dropFirst(cwd.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
    return (folder, "")
}

/// A local file's bytes for a rendered page, off the main thread; nil over `RenderKind.maxBytes` or unreadable.
func readForRender(_ path: String) async -> Data? {
    await Task.detached(priority: .userInitiated) { () -> Data? in
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? Int.max
        return size <= RenderKind.maxBytes ? try? Data(contentsOf: URL(fileURLWithPath: path)) : nil
    }.value
}

/// A diff's rendered sides and where their relative links point.
struct RenderedSides {
    var root: String
    var dir: String
    var sides: [RenderedPreviewView.Side]
}

extension AppState {
    /// The selected chat's project is on this Mac.
    var selectedProjectIsLocal: Bool {
        selectedTask.flatMap { project($0.projectId) }.map { runner(for: $0).isLocal } ?? false
    }

    /// The shown diff renders its file instead of Monaco.
    func diffPreviewShown(_ tab: DiffTab, isText: Bool) -> Bool {
        state.renderPreview && previewEligible(path: tab.path, isText: isText, local: selectedProjectIsLocal)
    }

    /// Both sides of the diff tab's file as pages, from the same places as the image preview (HD-142): the old one from
    /// git, the new one from the commit or the working tree. nil: no side could be read (or the project is on a server).
    func diffPreviewSides(_ tab: DiffTab) async -> RenderedSides? {
        guard let kind = RenderKind(path: tab.path), let task = selectedTask, let project = project(task.projectId) else { return nil }
        let runner = runner(for: project)
        guard runner.isLocal else { return nil }
        let max = RenderKind.maxBytes
        var old: Data?, new: Data?
        let root: String
        if let hash = tab.commit {
            guard let top = gitPanel.root else { return nil }
            root = top
            let git = Git(repo: top, runner: runner)
            old = (try? await git.blob(rev: hash + "^", path: tab.origPath ?? tab.path, maxBytes: max)) ?? nil
            new = (try? await git.blob(rev: hash, path: tab.path, maxBytes: max)) ?? nil
        } else {
            guard let folder = inspector.root, let changes = inspector.changes,
                  let file = changes.files.first(where: { $0.path == tab.path }) else { return nil }
            root = folder
            if file.change != .untracked && file.change != .added {
                old = (try? await Git(repo: folder, runner: runner).blob(rev: changes.from, path: "./" + (file.origPath ?? file.path), maxBytes: max)) ?? nil
            }
            if file.change != .deleted { new = await readForRender(folder + "/" + tab.path) }
        }
        // shortcut: the old side's relative files (css, images) come from today's folder, not from git; fine for a
        // review of the page itself, change when old assets matter.
        let dir = (tab.path as NSString).deletingLastPathComponent
        let sides: [RenderedPreviewView.Side] = switch (old, new) {
        case let (old?, new?):
            [.init(id: 0, title: L10n.diffImageBefore, page: renderedPage(old, kind: kind)),
             .init(id: 1, title: L10n.diffImageAfter, page: renderedPage(new, kind: kind))]
        case let (old?, nil): [.init(id: 0, page: renderedPage(old, kind: kind))]
        case let (nil, new?): [.init(id: 1, page: renderedPage(new, kind: kind))]
        case (nil, nil): []
        }
        return sides.isEmpty ? nil : RenderedSides(root: root, dir: dir, sides: sides)
    }
}

/// The diff tab's «Просмотр» body; reloads on every applied diff load whose file stamp changed (as the images do).
struct DiffRenderView: View {
    let app: AppState
    let tab: DiffTab
    let version: Int
    @State private var loaded: (key: String, stamp: String, result: RenderedSides?)?

    private var key: String { tab.path + "|" + (tab.commit ?? "") }

    var body: some View {
        Group {
            if let loaded, loaded.key == key {
                if let result = loaded.result {
                    RenderedPreviewView(root: result.root, dir: result.dir, sides: result.sides)
                } else {
                    Text(verbatim: L10n.diffPreviewFailed)
                        .font(Theme.Typography.mono.font())
                        .foregroundStyle(Theme.ui.text3)
                        .padding(.vertical, Theme.Diff.headerPaddingV)
                        .padding(.horizontal, Theme.Diff.headerPaddingH)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .task(id: "\(key)|\(version)|\(app.inspector.diffLoads)") {
            let key = key, stamp = app.diffImageStamp(tab)
            if let loaded, loaded.key == key, loaded.stamp == stamp { return }
            let result = await app.diffPreviewSides(tab)
            if !Task.isCancelled { loaded = (key, stamp, result) }
        }
    }
}
