import SwiftUI
import Workspace

/// What an empty session offers (decision #99): a host's terminal (#64) holds only ssh shells.
func noTabsChoices(hostShell: Bool) -> [LeafKind] { hostShell ? [.shell] : [.claude, .codex, .shell] }

extension AppState {
    /// The selected session has no tabs left: its area shows `NoTabsView`, nothing is launched by itself.
    var showsNoTabs: Bool { selectedTask?.tabs.isEmpty == true }
}

/// Tab area of a session without tabs: «Нет вкладок» and one button per tab kind (the «+» menu's choices).
struct NoTabsView: View {
    let app: AppState

    /// For the AppKit terminal area (SwiftUI's `Tab` would clash with `Workspace.Tab` there).
    @MainActor static func hosted(app: AppState) -> NSView {
        let view = NSHostingView(rootView: NoTabsView(app: app))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        VStack(spacing: Theme.sheetGap) {
            Text(L10n.emptyNoTabs).foregroundStyle(Theme.ui.text3)
            HStack(spacing: Theme.sheetGap) {
                ForEach(noTabsChoices(hostShell: app.selectedTask.map { app.isHostShellTask($0.id) } ?? false), id: \.self) { kind in
                    Button { app.addTab(kind) } label: {
                        HStack(spacing: Theme.iconGap) {
                            Image(nsImage: Icon.of(kind).image)
                            Text(title(kind)).foregroundStyle(Theme.ui.textStrong)
                            if kind == .shell { ShortcutHint(text: Shortcut.newTab.label) }
                        }
                        .padding(.vertical, Theme.tabPaddingV)
                        .padding(.horizontal, Theme.buttonPaddingH)
                    }
                    .buttonStyle(FilledRowStyle())
                }
            }
        }
        .font(.system(size: Theme.fontSize.sidebarRow))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func title(_ kind: LeafKind) -> String {
        switch kind {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell, .editor: L10n.terminalTab
        }
    }
}
