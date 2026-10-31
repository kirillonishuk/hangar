import Git
import SwiftUI

/// The inspector's Search tab (decision #91): query with Aa / .* / ab toggles, include / exclude globs, a status line of
/// constant height, results grouped by file. A click opens the line in the editor (one click previews, as in Files).
struct SearchPanel: View {
    let app: AppState
    private var model: SearchModel { app.search }

    var body: some View {
        VStack(spacing: 0) {
            fields
            statusLine
            if model.results.truncated { line(L10n.searchTruncated(SearchLimits.total)) }
            if model.results.skippedLines > 0, model.results.lines > 0 { line(L10n.searchSkipped(model.results.skippedLines)) }
            list
        }
        .onAppear { model.setTarget(app.searchTarget) }
        .onDisappear { model.cancel() }
        .onChange(of: app.searchTarget) { model.setTarget(app.searchTarget) }
    }

    private var fields: some View {
        VStack(spacing: Theme.SearchTab.gap) {
            SearchQueryField(model: model)
            if model.filtersShown {
                SearchGlobField(placeholder: L10n.searchInclude, text: Bindable(model).include)
                SearchGlobField(placeholder: L10n.searchExclude, text: Bindable(model).exclude)
            }
        }
        .padding(.horizontal, Theme.GitTab.padding)
        .padding(.top, Theme.GitTab.padding)
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.results.files) { file in
                    SearchFileHeader(file: file, collapsed: model.collapsed.contains(file.path)) { model.toggle(file.path) }
                        .popoverContextMenu { fileMenu(app: app, relative: file.path, opens: true) }
                    if !model.collapsed.contains(file.path) {
                        ForEach(Array(file.hits.enumerated()), id: \.offset) { _, hit in
                            SearchHitRow(hit: hit, path: file.path) { open(file.path, hit) }
                        }
                        if file.truncated { line(L10n.searchFileTruncated(SearchLimits.perFile)).padding(.leading, Theme.SearchTab.hitIndent - Theme.rowPaddingH) }
                    }
                }
            }
            .padding(.vertical, Theme.fileRowPaddingV)
        }
    }

    /// One line, always there (empty when idle), so results never move when a count or a notice appears.
    private var statusLine: some View {
        HStack(spacing: Theme.inlineGap) {
            Text(statusText)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.caption.font())
        .foregroundStyle(Theme.ui.text3)
        .frame(minHeight: Theme.GitTab.sectionHeight)
        .padding(.horizontal, Theme.rowPaddingH)
    }

    private var statusText: String {
        let r = model.results
        switch model.status {
        case .idle: return ""
        case .offline(let host): return L10n.hostOffline(host)
        case .failed(let error): return L10n.searchFailed(error)
        case .running where r.lines == 0: return L10n.searchRunning
        case .done where r.lines == 0: return r.skippedLines > 0 ? L10n.searchSkipped(r.skippedLines) : L10n.searchNothing
        case .running, .done: return L10n.searchSummary(matches: r.matches, files: r.files.count)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption.font())
            .foregroundStyle(Theme.ui.text3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.vertical, Theme.fileRowPaddingV)
    }

    private func open(_ path: String, _ hit: SearchHit) {
        // shortcut: a host terminal's results don't open (no editor for its files yet, phase 2 of #124).
        guard let root = model.target?.root, model.target?.link == nil else { return }
        app.openInEditor(path: root + "/" + path, line: hit.line, column: hit.column, preview: (NSApp.currentEvent?.clickCount ?? 1) < 2)
    }
}

/// The query: the Git tab's search field with the three toggles at its end.
private struct SearchQueryField: View {
    let model: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Theme.Input.iconGap) {
            TextField("", text: $model.text)
                .focused($focused)
                .onSubmit { model.run() }
                // Esc clears the query; on an empty field it hands focus back.
                .onExitCommand { if model.text.isEmpty { focused = false } else { model.text = "" } }
            if !model.text.isEmpty {
                Button { model.text = "" } label: {
                    IconView(icon: .close, size: Theme.Icon.inline, tint: Theme.ui.text3)
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help(L10n.searchClear)
            }
            HStack(spacing: Theme.SearchTab.toggleGap) {
                SearchToggle(label: Text(verbatim: "Aa"), help: L10n.searchCase, on: $model.caseSensitive)
                SearchToggle(label: Text(verbatim: "ab").underline(), help: L10n.searchWord, on: $model.wholeWord)
                SearchToggle(label: Text(verbatim: ".*"), help: L10n.searchRegex, on: $model.regex)
                SearchFiltersToggle(on: $model.filtersShown, active: model.filtersActive)
            }
        }
        .inputField(focused: focused, icon: .search, placeholder: model.text.isEmpty ? L10n.searchPlaceholder : nil)
        .onAppear { takeFocus() }
        .onChange(of: model.focusRequest) { takeFocus() }
    }

    /// ⇧⌘F may come before this field exists (the inspector was hidden): a request not yet served is served on appear.
    private func takeFocus() {
        guard model.focusRequest != model.focusServed else { return }
        model.focusServed = model.focusRequest
        DispatchQueue.main.async { focused = true }
    }
}

private struct SearchToggle: View {
    let label: Text
    let help: String
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: { label.font(Theme.Typography.monoSmall.font(.semibold)) }
            .buttonStyle(ChipStyle(on: on, square: true))
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The funnel opens the include / exclude fields (as VS Code's «…»); a dot while either holds a glob.
private struct SearchFiltersToggle: View {
    @Binding var on: Bool
    let active: Bool

    var body: some View {
        Button { on.toggle() } label: {
            IconView(icon: .filter, size: Theme.Icon.inline, tint: on ? Theme.ui.accentText : nil)
                .frame(width: Theme.Height.controlSmall, height: Theme.Height.controlSmall)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(Theme.ui.accentText)
                        .frame(width: Theme.SearchTab.filterDot, height: Theme.SearchTab.filterDot)
                        .opacity(active ? 1 : 0)
                }
        }
        .buttonStyle(ChipStyle(on: on, square: true))
        .help(active ? L10n.searchFiltersOn : L10n.searchFilters)
        .accessibilityLabel(active ? L10n.searchFiltersOn : L10n.searchFilters)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SearchGlobField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .focused($focused)
            .onExitCommand { focused = false }
            .inputField(focused: focused, mono: true, placeholder: text.isEmpty ? placeholder : nil)
    }
}

/// A file group: chevron, icon, name, folder (`text3`), the count of its lines.
private struct SearchFileHeader: View {
    let file: SearchFile
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        HoverRow(action: action) { _ in
            HStack(spacing: Theme.inlineGap) {
                IconView(icon: collapsed ? .chevronRight : .chevronDown, size: Theme.Icon.inline)
                FileIconView(name: name)
                NameFolderLayout(gap: Theme.inlineGap, minFolder: Theme.rowFolderMin) {
                    Text(name)
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(Theme.ui.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !dir.isEmpty {
                        Text(dir)
                            .font(Theme.Typography.caption.font())
                            .foregroundStyle(Theme.ui.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .clipped()
                    }
                }
                Text(verbatim: file.truncated ? "\(file.hits.count)+" : "\(file.hits.count)")
                    .font(Theme.Typography.monoSmall.font())
                    .foregroundStyle(Theme.ui.text3)
            }
            .padding(.horizontal, Theme.rowPaddingH)
            .frame(height: Theme.SearchTab.fileRow)
        }
        .help(file.path)
    }
}

/// One matching line, its matches marked as the Git tab marks search hits (`waiting` 28 %).
private struct SearchHitRow: View {
    let hit: SearchHit
    let path: String
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) { _ in
            Text(marked)
                .font(Theme.Typography.mono.font())
                .foregroundStyle(Theme.ui.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Theme.SearchTab.hitIndent)
                .padding(.trailing, Theme.rowPaddingH)
                .padding(.vertical, Theme.SearchTab.hitPaddingV)
        }
        .help("\(path):\(hit.line):\(hit.column)")
    }

    private var marked: AttributedString {
        let u = Array(hit.preview.utf16)
        var out = AttributedString()
        var at = 0
        for r in hit.ranges where r.lowerBound >= at && r.upperBound <= u.count {
            out += AttributedString(String(decoding: u[at..<r.lowerBound], as: UTF16.self))
            var m = AttributedString(String(decoding: u[r], as: UTF16.self))
            m.backgroundColor = Theme.ui.waiting.opacity(Theme.Opacity.fill)
            m.foregroundColor = Theme.ui.text0
            out += m
            at = r.upperBound
        }
        out += AttributedString(String(decoding: u[at...], as: UTF16.self))
        return out
    }
}
