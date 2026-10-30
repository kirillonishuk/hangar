import SwiftUI
import Workspace

/// What an empty session offers (decision #99): a host's terminal (#64) holds only ssh shells.
func noTabsChoices(hostShell: Bool) -> [LeafKind] { hostShell ? [.shell] : [.claude, .codex, .shell] }

extension AppState {
    /// The selected session has no tabs left: its area shows `NoTabsView`, nothing is launched by itself.
    var showsNoTabs: Bool { selectedTask?.tabs.isEmpty == true }
}

/// Tab area of a session without tabs: «Нет вкладок», «Продолжить» and one button per tab kind (the «+» menu's choices).
struct NoTabsView: View {
    let app: AppState

    /// For the AppKit terminal area (SwiftUI's `Tab` would clash with `Workspace.Tab` there).
    @MainActor static func hosted(app: AppState) -> NSView {
        let view = NSHostingView(rootView: NoTabsView(app: app))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        GeometryReader { geo in content(continueFit(geo.size, extra: 1)) }.clipped()
    }

    @ViewBuilder private func content(_ fit: (rows: Int, width: CGFloat)) -> some View {
        let task = app.selectedTask
        KindChoiceButtons(kinds: noTabsChoices(hostShell: task.map { app.isHostShellTask($0.id) } ?? false),
                          shellHint: Shortcut.newTab.label) { app.addTab($0) }
            .aboveCentered {
                Text(L10n.emptyNoTabs).foregroundStyle(Theme.ui.text2)  // §3.19
                // Inserted each time the session turns empty: the list rescans then (the tab just closed is in it).
                if let task, app.showsNoTabs {
                    ContinueList(app: app, taskId: task.id, fit: fit) { app.openConversation($0) }
                }
            }
            .font(Theme.Typography.body.font())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The new-tab / new-pane buttons (choice buttons of controls-v2 B′, the «+» menu's logos); Terminal's key is in its
/// tooltip only («Терминал — ⌘T»).
struct KindChoiceButtons: View {
    let kinds: [LeafKind]
    var disabled: Set<LeafKind> = []
    /// `⌘T` in an empty session, `↩` in a chooser pane.
    let shellHint: String
    let action: (LeafKind) -> Void

    var body: some View {
        // A narrow pane gets icon-only buttons (names in tooltips), never labels wrapped letter by letter.
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }
    }

    private func row(labels: Bool) -> some View {
        HStack(spacing: Theme.sheetGap) {
            ForEach(kinds, id: \.self) { kind in
                let off = disabled.contains(kind)
                // Not `.disabled`: a disabled button shows no tooltip, and the cap needs one.
                Button { if off { NSSound.beep() } else { action(kind) } } label: {
                    HStack(spacing: Theme.Space.iconGap) {
                        Image(nsImage: Icon.of(kind).image)
                        if labels {
                            Text(title(kind)).foregroundStyle(Theme.ui.text0).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, Theme.buttonPaddingH)
                    .frame(height: Theme.Height.controlRegular)
                }
                .buttonStyle(ChoiceButtonStyle())
                .focusable(false)  // a click must not leave the keyboard in the button: ↩ / Esc belong to the pane
                .opacity(off ? Theme.Opacity.inactive : 1)
                .help(off && kind == .editor ? L10n.paneEditorCap : kind == .shell ? "\(title(kind)) — \(shellHint)" : labels ? "" : title(kind))
                // VoiceOver: a dimmed (not enabled) button with the reason, as `.disabled` would read.
                .accessibilityRepresentation {
                    Button(title(kind)) { action(kind) }.disabled(off)
                }
                .accessibilityHint(off && kind == .editor ? L10n.paneEditorCap : "")
            }
        }
    }

    private func title(_ kind: LeafKind) -> String {
        switch kind {
        case .claude: "Claude"
        case .codex: "Codex"
        case .editor: L10n.editor
        case .shell, .choose: L10n.terminalTab
        }
    }
}

extension View {
    /// `content` stacked above this view, outside its layout: the buttons stay centred while the list loads in (no jump).
    func aboveCentered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        overlay(alignment: .top) {
            VStack(spacing: Theme.sheetGap) { content() }
                .fixedSize()
                .alignmentGuide(.top) { $0[.bottom] + Theme.sheetGap }
        }
    }
}
