import AppKit
import Combine

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let coordinator: SectionCoordinator
    let splitViewController = MainSplitViewController()

    private let dashboardButton = DashboardToggleButton()
    private let composeButton = NSButton()
    private let segmentedControl = NSSegmentedControl()
    private let bellButton = BadgeBellButton()
    private lazy var attentionPopover = AttentionPopoverController(
        store: AppEnvironment.shared.store,
        coordinator: coordinator
    )
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: SectionCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Min width preserves only the main content (its 640 floor + a little
        // slack). The sidebar is a collapsible split item, so as the window
        // narrows past sidebar + content the split view folds the sidebar away
        // rather than clamping the whole window at the wider combined minimum.
        window.minSize = NSSize(width: 680, height: 600)
        window.title = "Hermes"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        // Match the window backdrop to the content background so the floating
        // macOS 26 glass sidebar reads as the same surface (no two-tone shade).
        window.backgroundColor = Theme.bg
        super.init(window: window)

        // Assign content BEFORE sizing/centering. -[NSWindow setContentViewController:]
        // snaps the window to the controller's Auto Layout fitting size (≈ the split's
        // minimum thicknesses); doing it first would clobber the launch size and make
        // the window open cramped at its minimum. Size and place the window afterward.
        window.contentViewController = splitViewController
        _ = splitViewController.view // force-load so the tracking separator can find the split view

        let toolbar = NSToolbar(identifier: "HermesMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.sections]
        window.toolbar = toolbar

        // Restore the user's last frame if there is one; otherwise open at the
        // default content size, centered. (setFrameAutosaveName alone won't undo the
        // fitting-size snap above, so set the size explicitly first.)
        window.setContentSize(NSSize(width: 1280, height: 820))
        let restored = window.setFrameUsingName("HermesMainWindow")
        window.setFrameAutosaveName("HermesMainWindow")
        if !restored { window.center() }

        window.delegate = self
        coordinator.attach(to: splitViewController)
        bind()
    }

    /// Width at/under which the sidebar folds so the window can keep shrinking
    /// down to the main content's own minimum (sidebar 270 + content headroom).
    private static let sidebarFoldWidth: CGFloat = 1080

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Attention count shown on the bell (0 hides the badge).
    func setBadge(count: Int) {
        bellButton.badgeCount = count
    }

    /// Anchors the needs-attention popover to the toolbar bell (bell click,
    /// View ▸ Needs Attention ⌘9).
    func showAttentionPopover() {
        attentionPopover.toggle(relativeTo: bellButton)
    }

    private func bind() {
        coordinator.$currentSection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] section in
                self?.syncToolbar(for: section)
            }
            .store(in: &cancellables)

        Theme.shared.accentPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.dashboardButton.refreshTint()
                self?.bellButton.refreshTint()
            }
            .store(in: &cancellables)

        AppEnvironment.shared.store.$attentionItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.setBadge(count: items.count)
            }
            .store(in: &cancellables)
    }

    private func syncToolbar(for section: AppSection) {
        if let index = section.segmentIndex {
            segmentedControl.selectedSegment = index
        } else {
            segmentedControl.selectedSegment = -1
        }
        dashboardButton.isOn = section == .dashboard
    }

    // MARK: - Actions

    // MARK: - NSWindowDelegate

    /// Fold the sidebar as the window narrows so it can shrink to the main
    /// content's own minimum instead of clamping at sidebar + content width.
    /// Fires during live resize with the proposed size before the min-size
    /// clamp, so collapsing here lowers the floor and lets the drag continue.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        splitViewController.splitViewItems.first?.isCollapsed =
            frameSize.width < Self.sidebarFoldWidth
        return frameSize
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let section = AppSection.forSegment(sender.selectedSegment) else { return }
        coordinator.navigate(to: section)
    }

    @objc private func composeClicked(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.newConversation(_:)), to: nil, from: sender)
    }

    @objc private func dashboardClicked(_ sender: Any?) {
        coordinator.toggleDashboard()
    }

    @objc private func bellClicked(_ sender: Any?) {
        showAttentionPopover()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The tracking separator pins to the 270 pt sidebar divider, so items
        // before it share the sidebar zone. The handoff's Dashboard control is
        // icon-only, so all three controls fit beside the traffic-light inset.
        [.toggleSidebar, .compose, .dashboard, .sidebarSeparator,
         .flexibleSpace, .sections, .flexibleSpace, .bell, .gear]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: .sidebarSeparator,
                splitView: splitViewController.splitView,
                dividerIndex: 0
            )

        case .dashboard:
            dashboardButton.target = self
            dashboardButton.action = #selector(dashboardClicked(_:))
            let item = NSToolbarItem(itemIdentifier: .dashboard)
            item.view = dashboardButton
            item.label = "Dashboard"
            item.toolTip = "Toggle Overview"
            return item

        case .compose:
            composeButton.image = NSImage(systemSymbolName: "square.and.pencil",
                                          accessibilityDescription: "New Conversation")
            composeButton.bezelStyle = .texturedRounded
            composeButton.target = self
            composeButton.action = #selector(composeClicked(_:))
            let item = NSToolbarItem(itemIdentifier: .compose)
            item.view = composeButton
            item.label = "New Conversation"
            item.toolTip = "New Conversation"
            // Keep this primary action visible in the tight sidebar toolbar zone.
            item.visibilityPriority = .high
            return item

        case .sections:
            segmentedControl.segmentCount = 3
            segmentedControl.trackingMode = .selectOne
            segmentedControl.segmentStyle = .automatic
            for (index, section) in [AppSection.chat, .skills, .automations].enumerated() {
                // No fixed segment width: width 0 autosizes each segment to its
                // label (design uses hug-content segments).
                segmentedControl.setLabel(section.title, forSegment: index)
            }
            segmentedControl.selectedSegment = 0
            segmentedControl.target = self
            segmentedControl.action = #selector(segmentChanged(_:))
            let item = NSToolbarItem(itemIdentifier: .sections)
            item.view = segmentedControl
            item.label = "Section"
            return item

        case .bell:
            bellButton.target = self
            bellButton.action = #selector(bellClicked(_:))
            let item = NSToolbarItem(itemIdentifier: .bell)
            item.view = bellButton
            item.label = "Needs Attention"
            item.toolTip = "Needs Attention"
            return item

        case .gear:
            let item = NSMenuToolbarItem(itemIdentifier: .gear)
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.label = "Settings"
            item.toolTip = "Settings"
            item.showsIndicator = false
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…",
                         action: #selector(AppDelegate.showSettings(_:)),
                         keyEquivalent: "")
            menu.addItem(withTitle: "Check for Updates…",
                         action: #selector(AppDelegate.checkForUpdates(_:)),
                         keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "About Hermes",
                         action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                         keyEquivalent: "")
            item.menu = menu
            return item

        default:
            return nil
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let dashboard = NSToolbarItem.Identifier("hermes.dashboard")
    static let compose = NSToolbarItem.Identifier("hermes.compose")
    static let sidebarSeparator = NSToolbarItem.Identifier("hermes.sidebarSeparator")
    static let sections = NSToolbarItem.Identifier("hermes.sections")
    static let bell = NSToolbarItem.Identifier("hermes.bell")
    static let gear = NSToolbarItem.Identifier("hermes.gear")
}

// MARK: - Bell with count badge

final class BadgeBellButton: NSButton {
    var badgeCount: Int = 0 {
        didSet { refreshBadge() }
    }

    private let badgeLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        bezelStyle = .texturedRounded
        image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Needs Attention")

        badgeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 7
        badgeLabel.layer?.borderWidth = 1.5
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 7),
            badgeLabel.heightAnchor.constraint(equalToConstant: 14),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])
        refreshBadge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }

    func refreshTint() {
        let badge = Theme.acc
        let ring = Theme.bg
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.badgeLabel.layer?.backgroundColor = badge.cgColor
            self?.badgeLabel.layer?.borderColor = ring.cgColor
        }
    }

    private func refreshBadge() {
        badgeLabel.isHidden = badgeCount <= 0
        badgeLabel.stringValue = badgeCount > 9 ? "9+" : "\(badgeCount)"
        refreshTint()
    }
}
