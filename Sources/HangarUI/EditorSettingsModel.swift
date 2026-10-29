import AppKit
import Workspace

/// Settings → Appearance → Editor's state (#108, #109): the hovered and edited color, the preview's sample, a color being dragged (shown
/// in the preview on every frame, written and sent to the editors on release), the «Заменить свою тему?» question.
@MainActor @Observable final class EditorSettingsModel {
    struct Draft: Equatable {
        var color: EditorColor
        var hex: String
    }

    let app: AppState
    /// Runs a config write, showing its error under the page.
    @ObservationIgnored var save: (() throws -> Void) -> Void = { try? $0() }
    var hovered: EditorColor?
    /// The color whose popover is open, and where it hangs (a preview token's id; nil: its row in the list).
    var editing: EditorColor?
    var anchor: String?
    var sample: EditorPreviewSample = .typescript
    var expanded: Set<EditorColorSection> = [.syntax]
    var draft: Draft?
    /// A change that would drop «Своя»'s colors made on another base: waits for the confirmation.
    var pendingReplace: Draft?
    /// What the last change did («Создана тема «Своя»…»), under the page.
    var notice: String?
    /// The settings page's visible height: the preview gets shorter in a short window.
    var pageHeight: CGFloat = 0
    /// The page's content width: a wide window puts the preview beside the list.
    var pageWidth: CGFloat = 0
    var previewBeside: Bool { pageWidth >= Theme.EditorSettings.besidePageWidth }
    @ObservationIgnored private lazy var panelTarget = ColorPanelTarget { [weak self] hex in
        guard let self, let color = self.editing else { return }
        self.commit(color, EditorHex.with(hex, alpha: EditorHex.alpha(self.theme.hex(color))))
    }

    init(app: AppState) { self.app = app }

    /// The theme on screen: the config's, with the dragged color over it.
    var theme: EditorTheme {
        guard let draft else { return EditorTheme(app.config) }
        return EditorTheme(app.config.customizing(draft.color, draft.hex))
    }

    func open(_ color: EditorColor, anchor: String? = nil) {
        draft = nil
        self.anchor = anchor
        editing = color
    }

    func close() {
        editing = nil
        anchor = nil
        draft = nil
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    /// A row under the pointer: the preview shows a sample that has its color.
    func hover(_ color: EditorColor?) {
        hovered = color
        if let color, !sample.shows(color), let other = EditorPreviewSample.allCases.first(where: { $0.shows(color) }) {
            sample = other
        }
    }

    /// While dragging: the preview only.
    func preview(_ color: EditorColor, _ hex: String) { draft = Draft(color: color, hex: hex) }

    /// A color chosen (release, HEX, swatch, system palette): to the config and every open editor.
    func commit(_ color: EditorColor, _ hex: String) {
        guard let hex = HangarConfig.normalizedHex(hex) else { return }
        draft = nil
        if app.config.customizingReplacesColors { pendingReplace = Draft(color: color, hex: hex); return }
        apply(color, hex)
    }

    func confirmReplace() {
        guard let change = pendingReplace else { return }
        pendingReplace = nil
        apply(change.color, change.hex)
    }

    func cancelReplace() {
        pendingReplace = nil
        draft = nil
    }

    private func apply(_ color: EditorColor, _ hex: String) {
        let old = app.config
        let new = old.customizing(color, hex)
        guard new != old else { return }
        save { try app.setEditorTheme(new) }
        notice = old.editorPalette == .custom ? nil : L10n.s(.edCreated)
    }

    /// «Сбросить» (nil: «Сбросить всё»).
    func reset(_ color: EditorColor?) {
        draft = nil
        save { try app.setEditorTheme(app.config.resettingColor(color)) }
        notice = color == nil ? L10n.s(.edAllReset) : nil
    }

    /// The «Как у темы / Своя» switch.
    func follow(_ on: Bool) {
        let new = app.config.followingTheme(on)
        guard new != app.config else { return }
        draft = nil
        save { try app.setEditorTheme(new) }
        notice = nil
    }

    func openSystemPalette() {
        guard let color = editing else { return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        // Only the released color is applied (no config write per pixel of a drag).
        panel.isContinuous = false
        panel.setTarget(panelTarget)
        panel.setAction(#selector(ColorPanelTarget.changed(_:)))
        if let c = EditorHex.components(theme.hex(color)) {
            panel.color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        panel.orderFront(nil)
    }

    static func name(_ palette: EditorPalette) -> String {
        switch palette {
        case .darkModern: "VS Code Dark Modern"
        case .darkPlus: "VS Code Dark+"
        case .hangar: "Hangar"
        case .custom: L10n.s(.edCustom)
        case .theme: L10n.s(.edAsTheme)
        }
    }
}

/// NSColorPanel's target: the chosen color as `#rrggbb`.
final class ColorPanelTarget: NSObject {
    let changed: @MainActor (String) -> Void
    init(_ changed: @escaping @MainActor (String) -> Void) { self.changed = changed }

    @MainActor @objc func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        changed(EditorHex.from(r: c.redComponent, g: c.greenComponent, b: c.blueComponent))
    }
}
