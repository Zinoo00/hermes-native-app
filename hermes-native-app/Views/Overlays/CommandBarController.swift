//
//  CommandBarController.swift
//  hermes-native-app
//
//  Command Bar ⌘K (design spec §6 — the design ships only the menu item, so
//  this is the "minimal floating command palette" it calls for): floating
//  non-activating panel, 560 pt wide, centered in the main window's top
//  third. Navigation commands + fuzzy search over real session titles.
//

import AppKit

@MainActor
final class CommandBarController: NSObject, NSSearchFieldDelegate,
                                  NSTableViewDataSource, NSTableViewDelegate {

    private struct Item {
        enum Kind {
            case navigate(AppSection)
            case newConversation
            case interrupt
            case checkUpdates
            case session(storedID: String)
        }

        let title: String
        let detail: String
        let symbolName: String?
        let monogram: String?
        let kind: Kind
    }

    private let store: HermesStore
    private weak var coordinator: SectionCoordinator?

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var listHeightConstraint: NSLayoutConstraint?
    private var results: [Item] = []
    private var isHiding = false

    private static let panelWidth: CGFloat = 560
    private static let rowHeight: CGFloat = 34
    private static let maxVisibleRows = 9

    init(store: HermesStore, coordinator: SectionCoordinator) {
        self.store = store
        self.coordinator = coordinator
        super.init()
    }

    // MARK: Show / hide

    func toggle(over window: NSWindow?) {
        if panel?.isVisible == true {
            hide()
        } else if let window {
            show(over: window)
        }
    }

    func show(over window: NSWindow) {
        let panel = ensurePanel()
        parentWindow = window
        searchField.stringValue = ""
        rebuildResults(query: "")
        position(panel, over: window)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide() {
        guard !isHiding, let panel, panel.isVisible else { return }
        isHiding = true
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        isHiding = false
    }

    // MARK: Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = CommandBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow

        let chrome = CommandBarChromeView()
        chrome.material = .menu
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 12
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 1

        searchField.placeholderString = "Type a command or search conversations…"
        searchField.font = NSFont.systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.width = Self.panelWidth - 20
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        chrome.addSubview(searchField)
        chrome.addSubview(rule)
        chrome.addSubview(scrollView)
        let listHeight = scrollView.heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            rule.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 9),
            rule.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -6),
            listHeight,
        ])
        listHeightConstraint = listHeight

        panel.contentView = chrome
        self.panel = panel

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelResignedKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        return panel
    }

    @objc private func panelResignedKey(_ note: Notification) {
        hide()
    }

    private func position(_ panel: NSPanel, over window: NSWindow) {
        let height = panelHeight(forRows: results.count)
        let x = window.frame.midX - Self.panelWidth / 2
        let top = window.frame.maxY - window.frame.height * 0.18
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.panelWidth, height: height),
                       display: true)
    }

    private func panelHeight(forRows rows: Int) -> CGFloat {
        let visible = max(1, min(rows, Self.maxVisibleRows))
        return 10 + 28 + 9 + 1 + 4 + CGFloat(visible) * Self.rowHeight + 6
    }

    private func resizeToResults() {
        guard let panel else { return }
        let visible = max(1, min(results.count, Self.maxVisibleRows))
        listHeightConstraint?.constant = CGFloat(visible) * Self.rowHeight
        let height = panelHeight(forRows: results.count)
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }

    // MARK: Results

    private func allCommands() -> [Item] {
        var commands: [Item] = [
            Item(title: "Go to Chat", detail: "⌘1", symbolName: "bubble.left",
                 monogram: nil, kind: .navigate(.chat)),
            Item(title: "Go to Skills", detail: "⌘2", symbolName: "sparkles",
                 monogram: nil, kind: .navigate(.skills)),
            Item(title: "Go to Automations", detail: "⌘3", symbolName: "clock.arrow.circlepath",
                 monogram: nil, kind: .navigate(.automations)),
            Item(title: "Go to Dashboard", detail: "⌘0", symbolName: "square.grid.2x2",
                 monogram: nil, kind: .navigate(.dashboard)),
            Item(title: "Go to Settings", detail: "⌘,", symbolName: "gearshape",
                 monogram: nil, kind: .navigate(.settings)),
            Item(title: "New Conversation", detail: "⌘N", symbolName: "square.and.pencil",
                 monogram: nil, kind: .newConversation),
        ]
        if store.focusedSession?.isRunning == true {
            commands.append(Item(title: "Interrupt Current Turn", detail: "⌘.",
                                 symbolName: "stop.circle", monogram: nil, kind: .interrupt))
        }
        commands.append(Item(title: "Check for Updates…", detail: "",
                             symbolName: "arrow.down.circle", monogram: nil, kind: .checkUpdates))
        return commands
    }

    private func sessionItem(_ session: SessionSummary) -> Item {
        var title = session.title
        if title.isEmpty { title = session.preview }
        if title.isEmpty { title = "Conversation \(session.id.prefix(8))" }
        return Item(title: title,
                    detail: session.source?.capitalized ?? "",
                    symbolName: nil,
                    monogram: Self.monogramLetter(for: session.source),
                    kind: .session(storedID: session.id))
    }

    private func rebuildResults(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = allCommands() + store.sessions.prefix(6).map(sessionItem)
        } else {
            let commands = allCommands()
                .compactMap { item in Self.fuzzyScore(query: trimmed, in: item.title).map { (item, $0 + 1) } }
            let sessions = store.sessions.map(sessionItem)
                .compactMap { item in Self.fuzzyScore(query: trimmed, in: item.title).map { (item, $0) } }
            results = (commands + sessions)
                .sorted { $0.1 > $1.1 }
                .prefix(24)
                .map { $0.0 }
        }
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        resizeToResults()
    }

    /// Ordered-subsequence fuzzy match; higher score = better (consecutive
    /// runs and prefix matches boosted). nil = no match.
    private static func fuzzyScore(query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0
        var score = 0
        var lastMatch = -2
        for (i, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                score += (i == lastMatch + 1) ? 3 : 1
                if i == 0 { score += 2 }
                lastMatch = i
                qi += 1
            }
        }
        return qi == q.count ? score : nil
    }

    private static func monogramLetter(for source: String?) -> String {
        switch source?.lowercased() {
        case "telegram": return "T"
        case "discord": return "D"
        case "slack": return "S"
        case "signal": return "§"
        case "whatsapp": return "W"
        case "email", "imap": return "@"
        default: return "›"
        }
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < results.count else { return }
        execute(results[row])
    }

    private func executeSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return }
        execute(results[row])
    }

    private func execute(_ item: Item) {
        hide()
        switch item.kind {
        case .navigate(let section):
            coordinator?.navigate(to: section)
        case .newConversation:
            NSApp.sendAction(#selector(AppDelegate.newConversation(_:)), to: nil, from: self)
        case .interrupt:
            guard let session = store.focusedSession else { return }
            Task { await session.interrupt() }
        case .checkUpdates:
            NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: self)
        case .session(let storedID):
            let store = self.store
            let coordinator = self.coordinator
            Task {
                await store.selectSession(storedID: storedID)
                coordinator?.navigate(to: .chat)
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        rebuildResults(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            executeSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandBarRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count else { return nil }
        let item = results[row]
        let identifier = NSUserInterfaceItemIdentifier("CommandBarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CommandBarCellView
            ?? CommandBarCellView(identifier: identifier)
        cell.configure(title: item.title,
                       detail: item.detail,
                       symbolName: item.symbolName,
                       monogram: item.monogram)
        return cell
    }
}

// MARK: - Panel / row / cell pieces

/// Borderless panels refuse key status unless overridden — the palette needs
/// it for typing.
private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Frosted chrome whose hairline border tracks appearance changes.
private final class CommandBarChromeView: NSVisualEffectView {
    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = Theme.line2.cgColor
    }
}

/// Accent-soft rounded selection, matching the design's menu rows.
private final class CommandBarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        Theme.accSoft.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

private final class CommandBarCellView: NSView {
    private let iconView = NSImageView()
    private let chip = MonogramChipView(letter: "›")
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        iconView.contentTintColor = Theme.tx2
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = NSFont.systemFont(ofSize: 13)
        titleField.textColor = Theme.tx
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1

        detailField.font = NSFont.systemFont(ofSize: 11.5)
        detailField.textColor = Theme.tx3
        detailField.alignment = .right

        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(iconView)
        iconSlot.addSubview(chip)
        chip.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconSlot, titleField, NSView(), detailField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconSlot.widthAnchor.constraint(equalToConstant: 20),
            iconSlot.heightAnchor.constraint(equalToConstant: 20),
            iconView.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            chip.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            chip.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, detail: String, symbolName: String?, monogram: String?) {
        titleField.stringValue = title
        detailField.stringValue = detail
        if let symbolName {
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            iconView.isHidden = false
            chip.isHidden = true
        } else {
            iconView.isHidden = true
            chip.isHidden = false
            chip.letter = monogram ?? "›"
        }
    }
}
