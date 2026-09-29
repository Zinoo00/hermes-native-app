//
//  DashboardSidebarViewController.swift
//  hermes-native-app
//
//  Dashboard sidebar: three collapsible multi-select filter groups —
//  STATUS (outcome lenses), ACTIVITY (event taxonomy), PLATFORM (distinct
//  session sources) — plus the shared SidebarFooterView pinned at the
//  bottom. Whole rows toggle; selection tints icon + label with the accent
//  (no selection box); count badges keep their semantic colors.
//

import AppKit
import Combine

final class DashboardSidebarViewController: NSViewController {
    private let store = AppEnvironment.shared.store
    private let model = DashboardModel.shared
    private var cancellables = Set<AnyCancellable>()

    private let statusGroup = DashboardSidebarGroup(title: "Status")
    private let activityGroup = DashboardSidebarGroup(title: "Activity")
    private let platformGroup = DashboardSidebarGroup(title: "Platform")

    private var statusRows: [DashboardStatusLens: DashboardFilterRow] = [:]
    private var activityRows: [DashboardActivityLens: DashboardFilterRow] = [:]
    private var platformRows: [String: DashboardFilterRow] = [:]
    private var platformKeys: [String] = []

    // MARK: View construction

    override func loadView() {
        let root = NSView()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        for lens in DashboardStatusLens.allCases {
            let row = DashboardFilterRow(icon: .symbol(lens.symbolName), title: lens.title)
            row.onToggle = { [weak self] in self?.model.toggleStatus(lens) }
            statusRows[lens] = row
        }
        statusGroup.setRows(DashboardStatusLens.allCases.compactMap { statusRows[$0] })

        for lens in DashboardActivityLens.allCases {
            let row = DashboardFilterRow(icon: .symbol(lens.symbolName), title: lens.title)
            row.onToggle = { [weak self] in self?.model.toggleActivity(lens) }
            activityRows[lens] = row
        }
        activityGroup.setRows(DashboardActivityLens.allCases.compactMap { activityRows[$0] })

        for (index, group) in [statusGroup, activityGroup, platformGroup].enumerated() {
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            group.topMargin = index == 0 ? 12 : 14
        }

        let footer = SidebarFooterView(store: store)
        root.addSubview(footer)

        stack.pin(to: document, insets: NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0))
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])

        view = root
    }

    // MARK: Bindings

    override func viewDidLoad() {
        super.viewDidLoad()

        model.$events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        store.$attentionItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        model.$selectedStatuses
            .combineLatest(model.$selectedActivities, model.$selectedPlatforms)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.refresh() }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in self?.refresh() }

        refresh()
    }

    private func refresh() {
        let counts = model.counts

        // STATUS — semantic badge colors regardless of selection.
        statusRows[.flagged]?.setBadge(count: counts.flagged, color: Theme.danger, background: DashboardColors.dangerSoft)
        statusRows[.awaiting]?.setBadge(count: counts.awaiting, color: Theme.acc, background: Theme.accSoft)
        statusRows[.done]?.setBadge(count: counts.done, color: Theme.ok, background: DashboardColors.okSoft)
        for lens in DashboardStatusLens.allCases {
            statusRows[lens]?.isSelectedRow = model.selectedStatuses.contains(lens)
        }

        // ACTIVITY — neutral counts.
        let activityCounts: [DashboardActivityLens: Int] = [
            .messages: counts.messages,
            .automations: counts.automations,
            .subagents: counts.subagents,
            .learning: counts.learning,
        ]
        for lens in DashboardActivityLens.allCases {
            activityRows[lens]?.setBadge(count: activityCounts[lens] ?? 0, color: nil, background: nil)
            activityRows[lens]?.isSelectedRow = model.selectedActivities.contains(lens)
        }

        // PLATFORM — rebuilt when the distinct source set changes.
        let platforms = model.platforms
        let keys = platforms.map(\.key)
        if keys != platformKeys {
            platformKeys = keys
            platformRows = [:]
            let rows = platforms.map { platform -> DashboardFilterRow in
                let row = DashboardFilterRow(icon: .monogram(platform.glyph), title: platform.name)
                row.onToggle = { [weak self] in self?.model.togglePlatform(platform.key) }
                platformRows[platform.key] = row
                return row
            }
            platformGroup.setRows(rows)
        }
        platformGroup.setEmptyHint(platforms.isEmpty ? "No sessions yet" : nil)
        for platform in platforms {
            let row = platformRows[platform.key]
            row?.setBadge(count: counts.platformCounts[platform.key] ?? 0, color: nil, background: nil)
            row?.isSelectedRow = model.selectedPlatforms.contains(platform.key)
        }
    }
}

// MARK: - Collapsible group

/// Section header (uppercase label + chevron, no hover fill) over a column
/// of filter rows; clicking the header collapses the rows with an animated
/// chevron rotation.
final class DashboardSidebarGroup: NSView {
    private let headerControl: DashboardClickRow
    private let chevron = NSImageView()
    private let rowsStack = NSStackView()
    private let emptyHintField = NSTextField(labelWithString: "")
    private var topConstraint: NSLayoutConstraint?
    private var isExpanded = true

    var topMargin: CGFloat = 12 {
        didSet { topConstraint?.constant = topMargin }
    }

    init(title: String) {
        var toggleAction: (() -> Void)?
        headerControl = DashboardClickRow { toggleAction?() }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toggleAction = { [weak self] in self?.toggle() }

        let label = SectionLabelField(title)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        chevron.contentTintColor = Theme.tx3

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let headerStack = NSStackView(views: [label, spacer, chevron])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 6
        headerStack.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerControl.addSubview(headerStack)
        headerStack.pin(to: headerControl)
        addSubview(headerControl)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 1
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)

        emptyHintField.font = NSFont.systemFont(ofSize: 11)
        emptyHintField.textColor = Theme.tx3
        emptyHintField.isHidden = true
        emptyHintField.translatesAutoresizingMaskIntoConstraints = false

        let top = headerControl.topAnchor.constraint(equalTo: topAnchor, constant: topMargin)
        topConstraint = top
        NSLayoutConstraint.activate([
            top,
            headerControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rowsStack.topAnchor.constraint(equalTo: headerControl.bottomAnchor, constant: 2),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bottomAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setRows(_ rows: [NSView]) {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        rowsStack.addArrangedSubview(emptyHintField)
    }

    /// Quiet placeholder when a group has no real data yet.
    func setEmptyHint(_ hint: String?) {
        emptyHintField.stringValue = hint ?? ""
        emptyHintField.isHidden = hint == nil
    }

    private func toggle() {
        isExpanded.toggle()
        chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
        Motion.animate(0.2) {
            self.rowsStack.isHidden = !self.isExpanded
        }
    }
}

// MARK: - Filter row

/// Whole-row-clickable multi-select filter row: icon (SF symbol or
/// monochrome monogram chip), label, trailing count badge. Selected state
/// tints icon + label with the accent — no selection box.
final class DashboardFilterRow: NSControl {
    enum Icon {
        case symbol(String)
        case monogram(String)
    }

    var onToggle: (() -> Void)?

    var isSelectedRow = false {
        didSet { applySelection() }
    }

    private let iconImageView: NSImageView?
    private let label: NSTextField
    private let badge = DashboardCountBadge()
    private var isHovering = false

    init(icon: Icon, title: String) {
        let iconContainer = NSView()
        iconContainer.constrainSize(NSSize(width: 24, height: 24))

        let iconView: NSView
        switch icon {
        case .symbol(let name):
            let imageView = NSImageView()
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            imageView.symbolConfiguration = .init(pointSize: 12, weight: .medium)
            imageView.contentTintColor = Theme.tx2
            iconView = imageView
            iconImageView = imageView
        case .monogram(let glyph):
            // Platform chips stay monochrome per the design's restraint.
            iconView = MonogramChipView(letter: glyph)
            iconImageView = nil
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)
        iconView.center(in: iconContainer)

        label = NSTextField(labelWithString: title)
        label.font = Theme.bodyFont
        label.textColor = Theme.tx
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [iconContainer, label, spacer, badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Semantic badge colors; nil = plain neutral count (tx3, no wash).
    /// Zero counts always render quiet (tx3, no wash).
    func setBadge(count: Int, color: NSColor?, background: NSColor?) {
        if count > 0, let color, let background {
            badge.configure(text: "\(count)", color: color, background: background)
        } else {
            badge.configure(text: "\(count)", color: Theme.tx3, background: nil)
        }
    }

    private func applySelection() {
        iconImageView?.contentTintColor = isSelectedRow ? Theme.acc : Theme.tx2
        label.textColor = isSelectedRow ? Theme.acc : Theme.tx
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isHovering ? Theme.bgHover.cgColor : NSColor.clear.cgColor
    }
}

// MARK: - Count badge

/// Small pill count: semantic color on a soft wash, or quiet tx3 when zero.
final class DashboardCountBadge: NSView {
    private let label = NSTextField(labelWithString: "0")
    private var background: NSColor?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.tx3
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
        label.pin(to: self, insets: NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, color: NSColor, background: NSColor?) {
        label.stringValue = text
        label.textColor = color
        self.background = background
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (background ?? .clear).cgColor
    }
}

