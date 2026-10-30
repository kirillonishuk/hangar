import AppKit
import SwiftUI

/// An empty area (spec §3.19): one phrase `body` `text2` in the centre — what to do — and at most two regular buttons.
/// No data → no frame or placeholder box.
struct EmptyPrompt<Buttons: View>: View {
    let text: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: Theme.Space.s3) {
            Text(verbatim: text)
                .font(Theme.Typography.body.font())
                .foregroundStyle(Theme.ui.text2)
                .multilineTextAlignment(.center)
            HStack(spacing: Theme.Space.s2) { buttons }
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The chat area's empties: no project yet, or no chat chosen; each with its one primary button.
enum EmptyArea { case noProject, noChat }

/// Hosted for the AppKit terminal area (SwiftUI's `Tab` would clash with `Workspace.Tab` there).
@MainActor func emptyAreaView(_ area: EmptyArea, app: AppState, action: @escaping () -> Void) -> NSView {
    let host = NSHostingView(rootView: EmptyAreaView(area: area, app: app, action: action))
    host.sizingOptions = []
    return host
}

/// The texts are read in `body` after `app.language`: a language switch redraws them.
private struct EmptyAreaView: View {
    let area: EmptyArea
    let app: AppState
    let action: () -> Void

    var body: some View {
        let _ = app.language
        let (text, title, shortcut): (String, String, Shortcut) = switch area {
        case .noProject: (L10n.s(.emptyNoProject), L10n.addProject, .addProject)
        case .noChat: (L10n.emptyNoTask, L10n.newTask, .newTask)
        }
        EmptyPrompt(text: text) {
            Button(title, action: action)
                .buttonStyle(.hangar(.primary))
                .help(L10n.help(title, shortcut))
        }
    }
}

/// The empty state of an inspector list (no changes, no commits, an empty folder): its one phrase, centred under the
/// list's header (a list has no room for buttons).
struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.body.font())
            .foregroundStyle(Theme.ui.text2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.s4)
            .padding(.vertical, Theme.Space.s8)
    }
}
