import AppKit

/// Sidebar (fixed 270pt, collapsible, system vibrancy) + content. The split
/// items host stable containers; the coordinator swaps children inside them.
final class MainSplitViewController: NSSplitViewController {
    static let sidebarWidth: CGFloat = 270

    private let sidebarContainer = ContainerViewController()
    private let contentContainer = ContainerViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "HermesMainSplit"

        // macOS 26 sidebar: floating inset glass pane with vibrancy. The item
        // supplies the material + concentric-glass container and insets its
        // content below the toolbar automatically, so the container stays
        // transparent (color nil) and does not pin to the safe area itself —
        // that would double-inset inside the glass container.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarContainer)
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentContainer)
        contentItem.minimumThickness = 640
        addSplitViewItem(contentItem)
    }

    func showSidebar(_ viewController: NSViewController) {
        sidebarContainer.show(viewController)
    }

    func showContent(_ viewController: NSViewController) {
        contentContainer.show(viewController)
    }
}

/// Minimal transparent container that swaps a single child view controller.
/// Transparent so the sidebar item's vibrancy material shows through; the
/// content item's children supply their own opaque backgrounds.
final class ContainerViewController: NSViewController {
    private var current: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ viewController: NSViewController) {
        guard viewController !== current else { return }
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(viewController)
        let child = viewController.view
        child.frame = view.bounds
        child.autoresizingMask = [.width, .height]
        view.addSubview(child)
        current = viewController
    }
}
