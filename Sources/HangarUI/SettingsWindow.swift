import AppKit
import Integration
import SwiftUI
import Update
import Workspace

/// ⌘, / gear in the sidebar: System Settings style — categories on the left, the page's cards on the right.
/// Resizable; the size is remembered (frame autosave).
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(app: AppState) {
        model = SettingsModel(app: app)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.settingsSize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.sheet
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = Theme.settingsMinSize
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.setContentSize(Theme.settingsSize)
        super.init(window: window)
        window.delegate = self
        // A new name with the wider default (#109): a frame saved at the old 760 × 560 doesn't keep it narrow.
        if Self.remembersFrame { window.setFrameAutosaveName("HangarSettings2") }
        updateTitle()
        observeTheme(#selector(applyTheme))
    }

    /// Verification runs (isolated state) don't write the user's defaults.
    private static var remembersFrame: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HANGAR_STATE_DIR"] == nil
        #else
        return true
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func updateTitle() { window?.title = L10n.settings }

    @objc private func applyTheme() { window?.backgroundColor = Theme.sheet }

    func present(over parent: NSWindow?) {
        guard let window else { return }
        // Already open (⌘, again): only bring it forward, keep the typed draft.
        if !window.isVisible {
            if let parent {
                let p = parent.frame
                window.setFrameOrigin(NSPoint(x: p.midX - window.frame.width / 2, y: p.maxY - window.frame.height - Theme.settingsTopOffset))
            }
            model.externalEditor = model.app.config.externalEditor ?? ""
        }
        // Back in Settings: the agents' files are read again (MCP: a read; a write only if something is off).
        let app = model.app
        Task {
            await app.syncMCP()
            app.readStatusline()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The external-editor field saves on ↩ / focus loss; closing the window must not drop a typed value.
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.shouldClose() }

    /// Closes that skip `windowShouldClose` (app quit) still save the draft.
    func windowWillClose(_ notification: Notification) { model.commitExternalEditor() }
}

/// Settings state shared by the view and its window (draft of the text field, last write error).
@MainActor @Observable final class SettingsModel {
    let app: AppState
    var category: SettingsCategory = .general
    var externalEditor = ""
    var error: String?
    /// The draft whose save failed on close (the user has seen the error).
    private var refusedDraft: String?
    let lsp: LspServersModel
    let editorTheme: EditorSettingsModel

    init(app: AppState) {
        self.app = app
        var env = LspServersModel.Env(dir: app.lspDir, path: { [weak app] in await app?.loginShellPath() },
                                      projectRoot: { [weak app] in app?.localSessionRoot }, toolchain: xcrunFind,
                                      changed: { [weak app] in app?.languages.lspServersChanged() })
        #if DEBUG
        // A test feed (file:// fine) for the rust-analyzer download in verification runs.
        if let feed = ProcessInfo.processInfo.environment["HANGAR_LSP_FEED"].flatMap(URL.init(string:)) {
            env.feed = feed
            env.trusted = { $0.isFileURL || ReleaseFeed.isTrusted($0) }
        }
        #endif
        lsp = LspServersModel(env: env)
        editorTheme = EditorSettingsModel(app: app)
        editorTheme.save = { [weak self] change in self?.save(change) }
    }

    /// False when saving the draft fails: the window stays open with the error; closing again with the same draft closes.
    func shouldClose() -> Bool {
        if commitExternalEditor() { refusedDraft = nil; return true }
        defer { refusedDraft = externalEditor }
        return refusedDraft == externalEditor
    }

    @discardableResult func commitExternalEditor() -> Bool {
        let value = externalEditor.trimmingCharacters(in: .whitespaces)
        guard value != (app.config.externalEditor ?? "") else { return true }
        return save { try app.setConfig("external_editor", value) { $0.externalEditor = value.isEmpty ? nil : value } }
    }

    @discardableResult func save(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            error = nil
            return true
        } catch {
            uiLog.error("config write failed: \(String(describing: error), privacy: .public)")
            self.error = L10n.saveFailed(error.localizedDescription)
            return false
        }
    }
}

