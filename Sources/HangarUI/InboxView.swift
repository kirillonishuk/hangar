import AgentStatus
import SwiftUI

/// The bell's colour: something blocks an agent (accent), only errors (failed), nothing to count (muted).
enum BellTint: Equatable { case accent, failed, muted }

/// The number is the Dock's (permission + question + failed).
func inboxBell(_ items: [AttentionItem]) -> (count: Int, tint: BellTint) {
    let count = attentionCount(items)
    guard count > 0 else { return (0, .muted) }
    let blocked = items.contains { $0.attention.reason == .permission || $0.attention.reason == .question }
    return (count, blocked ? .accent : .failed)
}

/// «< 1 мин», «3 мин», «2 ч»: from `since` to the clock taken when the inbox opened (no ticking).
@MainActor func waitingTime(since: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(since) / 60)
    if minutes < 1 { return L10n.durationUnderMin }
    return minutes < 60 ? L10n.durationMin(minutes) : L10n.durationHour(minutes / 60)
}

/// The reason's glyph in an inbox row (permission and question must differ at a glance).
func inboxIcon(_ reason: AttentionReason) -> Icon {
    switch reason {
    case .permission: .lock
    case .question: .question
    case .failed: .alert
    case .limit: .limits
    case .done: .check
    }
}

/// A row's action: the leaf, the request it was shown for, what was pressed.
typealias InboxAction = (UUID, UUID?, NoticeAction) -> Void

/// Titlebar bell left of the inspector toggle; the count sits in reserved space, so the bell never moves.
struct InboxBell: View {
    let app: AppState
    let act: InboxAction

    var body: some View {
        let bell = inboxBell(app.attentionItems)
        let tint = Theme.Inbox.tint(bell.tint)
        Button { app.inboxClicked() } label: {
            HStack(spacing: Theme.Inbox.bellGap) {
                IconView(icon: .bell, tint: tint)
                Text(verbatim: bell.count > 99 ? "99+" : bell.count > 0 ? "\(bell.count)" : "")
                    .font(Theme.Typography.caption.font(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .frame(width: Theme.Inbox.countWidth, alignment: .leading)
            }
            .padding(.leading, Theme.Inbox.bellPaddingH)
            .frame(height: Theme.titleButtonSize)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
        .help(L10n.inbox)
        .accessibilityLabel(bell.count > 0 ? "\(L10n.inbox), \(bell.count)" : L10n.inbox)
        .popover(isPresented: Binding(get: { app.inboxShown }, set: { app.setInboxShown($0) }), arrowEdge: .bottom) {
            InboxPopover(app: app, act: act)
        }
    }
}

/// Urgent first, then «Недавно готово» (newest first) with «Очистить»; empty — «Никто не ждёт».
struct InboxPopover: View {
    let app: AppState
    let act: InboxAction

    var body: some View {
        let (urgent, done) = inboxSections(app.attentionItems)
        Group {
            if urgent.isEmpty, done.isEmpty {
                Text(L10n.nobodyWaiting)
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3)
                    .frame(maxWidth: .infinity, minHeight: Theme.Inbox.emptyHeight)
            } else if urgent.count + done.count > Theme.Inbox.scrollAfter {
                ScrollView { list(urgent, done) }.frame(height: Theme.Inbox.listHeight)
            } else {
                list(urgent, done)
            }
        }
        .padding(.vertical, Theme.Inbox.popoverPaddingV)
        .padding(.horizontal, Theme.Inbox.popoverPaddingH)
        .frame(width: Theme.Inbox.popoverWidth)
        .presentationBackground(Theme.ui.bg2)
    }

    private func list(_ urgent: [AttentionItem], _ done: [AttentionItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(urgent) { InboxRow(app: app, item: $0, act: act) }
            if !done.isEmpty {
                if !urgent.isEmpty {
                    Rectangle().fill(Theme.ui.line2).frame(height: 1).padding(.horizontal, -Theme.Inbox.popoverPaddingH)
                }
                HStack {
                    Text(L10n.inboxRecentDone).foregroundStyle(Theme.ui.text3)
                    Spacer(minLength: Theme.Inbox.rowGap)
                    Button(L10n.inboxClear) { app.clearDone() }
                        .buttonStyle(HeaderActionStyle())
                        .fixedSize()
                }
                .font(Theme.Typography.caption.font())
                .padding(.horizontal, Theme.Inbox.rowPaddingH)
                .padding(.top, urgent.isEmpty ? 0 : Theme.Inbox.sectionPaddingTop)
                ForEach(done) { InboxRow(app: app, item: $0, act: act) }
            }
        }
    }
}

/// Reason icon, «Проект › сессия», time; the text in one line with the banner's buttons. A click opens the leaf.
private struct InboxRow: View {
    let app: AppState
    let item: AttentionItem
    let act: InboxAction
    @State private var replying = false
    /// «Убрать» holds the keyboard: shown as under the pointer.
    @FocusState private var dismissFocused: Bool
    @State private var reply = ""
    @FocusState private var focused: Bool

    var body: some View {
        let n = notice(for: item, app: app)
        let a = item.attention
        VStack(alignment: .leading, spacing: Theme.Inbox.lineGap) {
            HoverRow(action: { act(item.leafId, a.requestKey, .open) }) { hover in
                HStack(alignment: .top, spacing: Theme.Inbox.rowGap) {
                    IconView(icon: inboxIcon(a.reason), size: Theme.Inbox.reasonIcon, tint: Theme.Inbox.reasonTint(a.reason))
                        .frame(height: Theme.Inbox.firstLine)
                    VStack(alignment: .leading, spacing: Theme.Inbox.lineGap) {
                        HStack(spacing: Theme.Inbox.rowGap) {
                            Text(verbatim: n.subtitle).foregroundStyle(Theme.ui.text2).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(verbatim: waitingTime(since: a.since, now: app.inboxClock))
                                .font(Theme.Typography.caption.font().monospacedDigit())
                                .foregroundStyle(Theme.ui.text3)
                        }
                        .font(Theme.Typography.secondary.font())
                        .frame(height: Theme.Inbox.firstLine)
                        HStack(spacing: Theme.railInset) {
                            Text(verbatim: n.body)
                                .font(Theme.Typography.body.font())
                                .foregroundStyle(Theme.ui.text1)
                                .truncationMode(.tail)
                            Spacer(minLength: Theme.Inbox.rowGap)
                            buttons(n, hover: hover)
                        }
                        .frame(height: Theme.Inbox.buttonHeight)
                    }
                }
                .lineLimit(1)
                .padding(.vertical, Theme.Inbox.rowPaddingV)
                .padding(.horizontal, Theme.Inbox.rowPaddingH)
            }
            .environment(\.rowHighlight, RowHighlight(radius: Theme.railItemRadius))
            .help(n.title)
            if replying {
                TextField("", text: $reply)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .inputField(focused: focused, placeholder: reply.isEmpty ? L10n.noticeReply : nil)
                    .onSubmit {
                        act(item.leafId, a.requestKey, .reply(reply))
                        reply = ""
                        replying = false
                    }
                    .onExitCommand { replying = false }
                    .onAppear { focused = true }
                    .padding(.horizontal, Theme.Inbox.rowPaddingH)
                    .padding(.bottom, Theme.Inbox.rowPaddingV)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(n.title)
    }

    /// The banner's buttons under the same conditions (`notice(for:)`'s category): «Разрешить» is the row's one
    /// filled `accent` action; done rows get «Убрать» only under the pointer (controls-v2 B′).
    @ViewBuilder private func buttons(_ n: AgentNotice, hover: Bool) -> some View {
        switch n.category {
        case .permissionAllow:
            InboxButton(title: L10n.noticeAllow, primary: true) { act(item.leafId, n.requestKey, .allow) }
        case .questionReply:
            InboxButton(title: L10n.noticeReply) { replying.toggle() }
        case .limit:
            InboxButton(title: L10n.noticeOpenLimits) { act(item.leafId, n.requestKey, .limits) }
        case .permission, .open:
            if item.attention.reason == .done {
                // Hidden at rest but still a button: Tab reaches it (and shows it), VoiceOver reads and presses it.
                InboxButton(title: L10n.inboxDismiss) { app.dismissDone(leafId: item.leafId) }
                    .focused($dismissFocused)
                    .opacity(hover || dismissFocused ? 1 : 0)
                    .allowsHitTesting(hover)
            }
        }
    }
}

private struct InboxButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(ActionButtonStyle(primary: primary))
            .fixedSize()
    }
}
