import AppKit

private final class FillViewController: NSViewController {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = color.cgColor
        view = v
    }
}

public final class MainWindowController: NSWindowController {
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.isMovableByWindowBackground = false
        window.backgroundColor = Theme.panel
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 800, height: 500)

        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin

        let sidebar = NSSplitViewItem(sidebarWithViewController: FillViewController(color: Theme.sidebar))
        sidebar.minimumThickness = Theme.sidebarMin
        sidebar.maximumThickness = Theme.sidebarMax
        sidebar.canCollapse = false
        sidebar.holdingPriority = .init(260)
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: FillViewController(color: Theme.panel)))

        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.center()
        // Apply default sidebar width after layout.
        split.splitView.setPosition(Theme.sidebarWidth, ofDividerAt: 0)
        super.init(window: window)
        window.setFrameAutosaveName("HangarMainWindow")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
