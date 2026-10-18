import SwiftUI

/// One sidebar row. The marker (dot/icon) sits at `Theme.gutterMarkerX` in both expanded and rail mode;
/// collapsing only cross-fades the labels, so nothing moves (only the sidebar width animates).
struct GutterRow<Marker: View, Expanded: View, Rail: View>: View {
    let collapsed: Bool
    var height = Theme.railRowHeight
    var textX = Theme.gutterTextX
    @ViewBuilder var marker: Marker
    @ViewBuilder var expanded: Expanded
    @ViewBuilder var rail: Rail

    var body: some View {
        ZStack(alignment: .leading) {
            marker
                .frame(width: Theme.iconSize, height: Theme.iconSize)
                .offset(x: Theme.gutterMarkerX - Theme.iconSize / 2)
            rail
                .padding(.leading, Theme.railTextX)
                .opacity(collapsed ? 1 : 0)
            expanded
                .padding(.leading, textX)
                .padding(.trailing, Theme.rowPaddingH)
                .opacity(collapsed ? 0 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
    }
}

/// Section header (caps, `text3`, 11.5 semibold, tracked): fades out in rail mode but keeps its height so rows don't jump.
struct SectionHeader: View {
    let title: String
    let collapsed: Bool
    var plusHelp = ""
    /// `+` without hover (empty state: nothing else says how to add the first project).
    var plusAlwaysVisible = false
    var plus: (() -> Void)?

    var body: some View {
        HoverRow { hover in
            HStack(spacing: 0) {
                Text(title).tracking(Theme.fontSize.section * Theme.fontSize.projectTracking)
                Spacer(minLength: 0)
                if let plus {
                    Button(action: plus) { IconView(icon: .newTask, size: Theme.smallIconSize).padding(Theme.railInset) }
                        .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                        .opacity(hover || plusAlwaysVisible ? 1 : 0)
                        .help(plusHelp)
                }
            }
            .font(.system(size: Theme.fontSize.section, weight: .semibold))
            .foregroundStyle(Theme.ui.text3)
            .padding(.leading, Theme.sectionTextX)
            .padding(.trailing, Theme.rowPaddingH - Theme.railInset)
            .frame(height: Theme.projectRowHeight)
            .opacity(collapsed ? 0 : 1)
            .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
        }
        .allowsHitTesting(!collapsed)
        .padding(.top, Theme.sectionGap)
    }
}

/// "+ Новая задача" fill (`hoverStrong`). With `width` the fill follows the visible sidebar width (content is laid
/// out wider and clipped in rail mode); without it the fill hugs the label (empty-state button).
struct FilledRowStyle: ButtonStyle {
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, pressed: configuration.isPressed, width: width)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        let width: CGFloat?
        @State private var hover = false

        var body: some View {
            label
                .background(alignment: .leading) {
                    let fill = RoundedRectangle(cornerRadius: Theme.railItemRadius)
                        .fill(Theme.ui.hoverStrong)
                        .brightness(pressed ? -0.03 : hover ? 0.04 : 0)
                    if let width {
                        fill.frame(width: max(0, width)).padding(.leading, Theme.railInset)
                    } else {
                        fill
                    }
                }
                .contentShape(Rectangle())
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        }
    }
}

/// Terminal area while there are no projects: "+ Добавить проект" (style of "+ Новая задача") and the ⌘⇧N hint.
struct EmptyStateView: View {
    let addProject: () -> Void

    /// For the AppKit terminal area (SwiftUI's `Tab` would clash with `Workspace.Tab` there).
    @MainActor static func hosted(addProject: @escaping () -> Void) -> NSView {
        let view = NSHostingView(rootView: EmptyStateView(addProject: addProject))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        VStack(spacing: Theme.sheetGap) {
            Button(action: addProject) {
                HStack(spacing: Theme.iconGap) {
                    IconView(icon: .newTask, active: true)
                    Text(L10n.addProject).foregroundStyle(Theme.ui.textStrong)
                }
                .padding(.vertical, Theme.tabPaddingV)
                .padding(.horizontal, Theme.buttonPaddingH)
            }
            .buttonStyle(FilledRowStyle())
            Text("⌘⇧N").font(.system(size: Theme.fontSize.footer)).foregroundStyle(Theme.ui.text3)
        }
        .font(.system(size: Theme.fontSize.sidebarRow))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
