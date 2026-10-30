import Git
import SwiftUI

/// The inspector's Git tab (redesign v1 §4), read-only: branches, search and filter chips, the log, and the selected
/// commit's details under a draggable divider — on a short window the details replace the log.
struct GitPanelView: View {
    let app: AppState
    private var model: GitPanelModel { app.gitPanel }
    /// The details' share of the room under the chips (dragged; per window, not saved).
    @State private var share = Theme.GitTab.detailsShare
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < Theme.GitTab.compactHeight
            VStack(spacing: 0) {
                if compact, model.selected != nil {
                    GitDetailsView(app: app, compact: true)
                } else {
                    GitBranchesBlock(model: model)
                    Color.clear.frame(height: Theme.GitTab.blockGap)
                    GitSearchField(model: model)
                    GitFilterChips(app: app, model: model)
                    notices
                    if model.selected != nil {
                        GeometryReader { room in
                            let h = detailsHeight(room.size.height)
                            VStack(spacing: 0) {
                                GitLogList(app: app, model: model)
                                divider(room.size.height)
                                GitDetailsView(app: app, compact: false).frame(height: h)
                            }
                        }
                    } else {
                        GitLogList(app: app, model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { model.tabShown = true }
        .onDisappear { model.tabShown = false }
    }

    private func detailsHeight(_ room: CGFloat) -> CGFloat {
        let lo = Theme.GitTab.minPane, hi = max(lo, room - Theme.GitTab.minPane)
        return min(max(room * share, lo), hi)
    }

    /// 1 pt `line` with a grip; dragging moves the share between the log and the details.
    private func divider(_ room: CGFloat) -> some View {
        Rectangle().fill(Theme.ui.line).frame(height: 1)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.GitTab.gripHeight / 2).fill(Theme.ui.line2)
                    .frame(width: Theme.GitTab.gripWidth, height: Theme.GitTab.gripHeight)
            }
            .frame(height: Theme.GitTab.dividerHit)
            .contentShape(Rectangle())
            .resizeCursor()
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let start = dragStart ?? share
                    dragStart = start
                    guard room > 0 else { return }
                    share = min(max(start - v.translation.height / room, 0.1), 0.9)
                }
                .onEnded { _ in dragStart = nil })
            .help(L10n.gitResizeHelp)
    }

    @ViewBuilder private var notices: some View {
        if model.offline, let host = app.selectedTask.flatMap({ app.project($0.projectId)?.host }) {
            GitNotice(text: L10n.hostOffline(host))
        } else if let error = model.error {
            GitNotice(text: L10n.gitFailed(error))
        } else if model.loaded, model.commits.isEmpty {
            EmptyNote(text: model.query == GitQuery() ? L10n.gitNoCommits : L10n.gitNothingFound)
        }
    }
}

/// A one-line `text3` remark (offline, git error, empty).
struct GitNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption.font())
            .foregroundStyle(Theme.ui.text3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.GitTab.padding)
            .padding(.vertical, Theme.GitTab.noticePaddingV)
    }
}

/// A tree or log row: the highlight inset 6 from the edges with radius 6 (as the sidebar's rows).
struct GitRow<Content: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) { content().frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(HoverButtonStyle(selected: selected, radius: Theme.GitTab.rowRadius))
            .padding(.horizontal, Theme.GitTab.rowInset)
    }
}

/// A small `text3` icon button (24 box) in a section header.
struct GitIconButton: View {
    let icon: Icon
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: Theme.GitTab.sectionIcon, tint: Theme.ui.text3)
                .frame(width: Theme.GitTab.sectionButton, height: Theme.GitTab.sectionButton)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.GitTab.rowRadius))
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Opacity.inactive)
        .help(help)
    }
}

/// Search field 28 (text or hash), the count of what was found, `×` to clear.
struct GitSearchField: View {
    let model: GitPanelModel
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Theme.Input.iconGap) {
            TextField("", text: $model.query.text)
                .focused($focused)
                .onKeyPress(.downArrow) { model.step(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.step(by: -1); return .handled }
                .onChange(of: model.searchFocusRequest) { focused = true }
                // Esc clears the search; on an empty field it hands focus back.
                .onExitCommand { if model.query.text.isEmpty { focused = false } else { model.query.text = "" } }
            if !model.query.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if model.loaded {
                    Text(L10n.gitFound(model.commits.count, more: model.hasMore))
                        .font(Theme.Typography.secondary.font())
                        .foregroundStyle(Theme.ui.text3)
                }
                Button { model.query.text = "" } label: {
                    IconView(icon: .close, size: Theme.smallIconSize, tint: Theme.ui.text3)
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help(L10n.gitClearFilter)
            }
        }
        .inputField(focused: focused, icon: .search, placeholder: model.query.text.isEmpty ? L10n.gitSearch : nil)
        .padding(.horizontal, Theme.GitTab.padding)
    }
}

extension View {
    /// Up/down resize cursor over a divider (dividers keep theirs, DESIGN.md «Курсор»).
    @ViewBuilder func resizeCursor() -> some View {
        if #available(macOS 15, *) { pointerStyle(.frameResize(position: .top, directions: .all)) } else { self }
    }
}
