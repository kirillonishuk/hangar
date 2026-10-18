import AppKit
import SwiftUI
import Workspace

/// Project settings (sheet 580, `new-task-v4` style): name, path with «Choose…», default branch (read-only until stage 2).
/// A missing folder is shown as an error and nothing is saved.
struct ProjectSettingsSheet: View {
    let project: Project
    let onSave: (_ name: String, _ path: String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var path: String
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case name, path }

    init(project: Project, onSave: @escaping (_ name: String, _ path: String) -> Void, onCancel: @escaping () -> Void) {
        self.project = project
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: project.name)
        _path = State(initialValue: project.path)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.statusDot) {
                Text(L10n.projectSettings)
                    .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                    .foregroundStyle(Theme.ui.sheetText)
                Text(project.name).font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text3)
            }
            .padding(.top, Theme.sheetHeaderTop)
            .padding(.bottom, Theme.sheetHeaderBottom)

            label(L10n.projectName)
            TextField("", text: $name)
                .focused($focus, equals: .name)
                .onSubmit(save)
                .modifier(SheetField(focused: focus == .name))

            label(L10n.projectPath)
            HStack(spacing: Theme.statusDot) {
                TextField("", text: $path)
                    .font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                    .focused($focus, equals: .path)
                    .onSubmit(save)
                    .onChange(of: path) { error = nil }
                    .modifier(SheetField(focused: focus == .path))
                Button(L10n.chooseEllipsis, action: choose).buttonStyle(SheetButton(primary: false))
            }
            if let error {
                Text(error).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.failed)
                    .padding(.top, Theme.railInset)
            }

            label(L10n.defaultBranch)
            HStack(spacing: Theme.statusDot) {
                Text(project.lastBaseBranch ?? "—").foregroundStyle(Theme.ui.text2)
                Text(L10n.defaultBranchLater).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
            }

            HStack(spacing: Theme.statusDot) {
                Text(L10n.escCancel).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
                Spacer(minLength: 0)
                Button(L10n.cancel, action: onCancel)
                    .buttonStyle(SheetButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save, action: save)
                    .buttonStyle(SheetButton(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : Theme.disabledButtonOpacity)
            }
            .padding(.vertical, Theme.sheetFooterPaddingV)
            .padding(.top, Theme.sheetGap)
        }
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.sheetWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .background(Theme.ui.sheet)
        .onAppear { focus = .name }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
            .padding(.top, Theme.sheetGap)
            .padding(.bottom, Theme.railInset)
    }

    private func save() {
        guard canSave else { return }
        let trimmed = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard folderExists(trimmed) else { error = L10n.folderMissing(trimmed); return }
        onSave(name, trimmed)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        // Modal over the sheet: a sheet can't host another sheet-modal panel.
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
