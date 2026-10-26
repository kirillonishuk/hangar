import AppKit
import WebKit

/// One WKWebView with Monaco (#80): the bundled page over `hangar-editor://`, no network (content rule list + CSP),
/// a non-persistent data store, and the typed bridge (`BridgeMessage` in, `EditorCommand` out).
@MainActor final class MonacoPage: NSObject, WKNavigationDelegate {
    enum Mode: String { case editor, diff }

    let webView: WKWebView
    var onMessage: ((BridgeMessage) -> Void)?
    private var ready = false
    var isReady: Bool { ready }
    private var pending: [EditorCommand] = []
    private static let handlerName = "hangar"

    init(mode: Mode, inline: Bool, minimap: Bool) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MonacoSchemeHandler(), forURLScheme: monacoScheme)
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true  // no half-styled flash while Monaco loads
        let settings: [String: Any] = [
            "mode": mode.rawValue, "theme": MonacoTheme.json, "css": MonacoTheme.css,
            "inline": inline, "minimap": minimap, "lang": L10n.resolve(L10n.language).rawValue,
            "fontSize": Theme.Editor.fontSize, "lineHeight": Theme.Editor.lineHeight,
            "strings": ["reload": L10n.editorReload, "keepMine": L10n.editorKeepMine, "conflict": L10n.editorConflict,
                        "minimap": L10n.editorMinimap],
            "menu": L10n.editorMenu,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: settings)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        config.userContentController.addUserScript(WKUserScript(source: "window.hangarConfig = \(json);",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")  // the panel color shows until the page paints
        #if DEBUG
        webView.isInspectable = true
        #endif
        config.userContentController.add(WeakHandler(self), contentWorld: .page, name: Self.handlerName)
        Self.withBlockList { [weak self] list in
            guard let self else { return }
            if let list { self.webView.configuration.userContentController.add(list) }
            self.webView.load(URLRequest(url: URL(string: "\(monacoScheme)://app/hangar/index.html")!))
        }
    }

    /// Ends the bridge (the handler would otherwise keep the page alive).
    func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        onMessage = nil
    }

    func send(_ command: EditorCommand) {
        guard ready else { pending.append(command); return }
        webView.callAsyncJavaScript("hangar.receive(c)", arguments: ["c": command.json], in: nil, in: .page) { result in
            if case .failure(let error) = result { uiLog.error("editor command failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// The buffer of an open file (to save it before closing).
    func text(of path: String) async -> String? {
        guard ready else { return nil }
        return try? await webView.callAsyncJavaScript("return hangar.text(p)", arguments: ["p": path], contentWorld: .page) as? String
    }

    #if DEBUG
    func run(_ js: String) { webView.evaluateJavaScript(js) }
    #endif

    fileprivate func receive(_ message: WKScriptMessage) {
        // Only the bundled page's own frame speaks for the editor.
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == monacoScheme,
              let m = BridgeMessage.decode(message.body) else {
            uiLog.error("editor: rejected a page message")
            return
        }
        if case .log(let text) = m { uiLog.error("editor page: \(text, privacy: .public)"); return }
        if case .clipboard(let action) = m {
            // The context menu's Cut / Copy / Paste go through WebKit's own edit commands (as ⌘X/⌘C/⌘V): no clipboard prompt.
            NSApp.sendAction(action.selector, to: webView, from: nil)
            return
        }
        if m == .ready {
            ready = true
            let queued = pending
            pending = []
            queued.forEach(send)
        }
        onMessage?(m)
    }

    // MARK: Navigation: the page itself and nothing else

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.scheme == monacoScheme && action.targetFrame?.isMainFrame == true ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The buffers are gone with the process; reload the page (the owner reopens its files on `.ready`).
        ready = false
        webView.load(URLRequest(url: URL(string: "\(monacoScheme)://app/hangar/index.html")!))
    }

    // MARK: No network

    private static var blockList: WKContentRuleList?
    private static var compiling: [(WKContentRuleList?) -> Void]?

    /// http(s) and ws(s) are blocked for every load of the page (compiled once per launch into a temp store).
    private static func withBlockList(_ then: @escaping (WKContentRuleList?) -> Void) {
        if let blockList { return then(blockList) }
        if compiling != nil { compiling?.append(then); return }
        compiling = [then]
        // url-filter has no `|`: one rule per scheme.
        let rules = "[" + ["^https?://", "^wss?://", "^ftp://"]
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }.joined(separator: ",") + "]"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-editor-rules-\(getuid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WKContentRuleListStore(url: dir) ?? WKContentRuleListStore.default()
        store?.compileContentRuleList(forIdentifier: "hangar-editor-no-network", encodedContentRuleList: rules) { list, error in
            MainActor.assumeIsolated {
                if let error { uiLog.error("editor rule list: \(String(describing: error), privacy: .public)") }
                blockList = list
                let waiting = compiling ?? []
                compiling = nil
                waiting.forEach { $0(list) }
            }
        }
    }
}

/// The content controller keeps its handlers strongly; this one doesn't keep the page.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var page: MonacoPage?
    init(_ page: MonacoPage) { self.page = page }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { page?.receive(message) }
    }
}
