import CoreGraphics

/// Which side panels are on screen (HD-162).
struct PanelLayout: Equatable {
    var inspector: Bool
    var sidebarRail: Bool
}

/// The adaptive window (HD-162): what the user asked for, then — while the chat column would get narrower than
/// `chatMin` — first the inspector goes, then the sidebar shrinks to its rail. Computed from the saved widths, not the
/// current frames, so a resize back restores the panels. `keep…`: the user showed that panel in a narrow window (it stays).
func panelLayout(window: CGFloat, sidebar: CGFloat, inspector: CGFloat, wantsInspector: Bool, wantsRail: Bool, chatOnly: Bool,
                 keepInspector: Bool = false, keepSidebar: Bool = false,
                 chatMin: CGFloat = Theme.chatMin, rail: CGFloat = Theme.sidebarRailWidth) -> PanelLayout {
    if chatOnly { return PanelLayout(inspector: false, sidebarRail: true) }
    var layout = PanelLayout(inspector: wantsInspector, sidebarRail: wantsRail)
    // 1 pt per divider of a shown panel.
    func chat() -> CGFloat {
        window - (layout.sidebarRail ? rail : sidebar) - 1 - (layout.inspector ? inspector + 1 : 0)
    }
    if layout.inspector, !keepInspector, chat() < chatMin { layout.inspector = false }
    if !layout.sidebarRail, !keepSidebar, chat() < chatMin { layout.sidebarRail = true }
    return layout
}

/// The inspector's drag limits: from `inspectorMin` up to half the window (HD-162).
func inspectorMaxWidth(window: CGFloat) -> CGFloat {
    max(Theme.inspectorMin, (window * Theme.inspectorMaxFraction).rounded(.down))
}

/// The persisted inspector width within the drag limits (state.json may hold anything).
func clampInspectorWidth(_ w: CGFloat, window: CGFloat) -> CGFloat {
    min(max(w, Theme.inspectorMin), inspectorMaxWidth(window: window))
}

/// The persisted sidebar width within its drag limits.
func clampSidebarWidth(_ w: CGFloat) -> CGFloat {
    min(max(w, Theme.sidebarMin), Theme.sidebarMax)
}

/// The diff pane is too narrow for «Рядом» (a pane not laid out yet is not).
func diffIsNarrow(width: CGFloat) -> Bool {
    width > 0 && width < Theme.diffSideBySideMin
}
