import AppKit

/// The four opinionated permission modes the design layers over hermes'
/// approval/allowlist primitives. `plan` is design-only (no backend support)
/// and stays disabled.
enum ChatPermissionMode: String, CaseIterable {
    case askFirst
    case plan
    case auto
    case fullAccess

    var label: String {
        switch self {
        case .askFirst: return "Ask first"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .fullAccess: return "Full access"
        }
    }

    /// Exact descriptions from the design.
    var detail: String {
        switch self {
        case .askFirst:
            return "Confirms writes, shell commands, and sends. Reads and allowlisted commands run freely."
        case .plan:
            return "Read-only. Explores and drafts a plan — no edits, commands, or messages until you approve."
        case .auto:
            return "Runs tools without asking, bounded by your command allowlist and container isolation."
        case .fullAccess:
            return "No prompts; every action auto-approved. Best only in an isolated sandbox."
        }
    }

    var dotColor: NSColor {
        switch self {
        case .askFirst: return Theme.tx3
        case .plan: return Theme.acc
        case .auto: return Theme.ok
        case .fullAccess: return Theme.danger
        }
    }

    var isSelectable: Bool { self != .plan }

    /// approval.respond auto-answer this mode implies (nil = ask the user).
    var autoApprovalChoice: ApprovalChoice? {
        switch self {
        case .auto: return .session
        case .fullAccess: return .always
        case .askFirst, .plan: return nil
        }
    }

    /// ⇧⇥ cycling order (skips the disabled Plan mode).
    var next: ChatPermissionMode {
        switch self {
        case .askFirst: return .auto
        case .auto: return .fullAccess
        case .fullAccess: return .askFirst
        case .plan: return .askFirst
        }
    }
}

/// NSPopUpButton-styled pill: status dot + label + accent chevron well.
/// Click opens the PERMISSION MODE popover.
final class ChatPermissionModeControl: NSControl {

    var mode: ChatPermissionMode = .askFirst {
        didSet {
            label.stringValue = mode.label
            needsDisplay = true
            dot.needsDisplay = true
        }
    }

    var onModeChange: ((ChatPermissionMode) -> Void)?

    private let dot = ChatPermissionDotView()
    private let label = NSTextField(labelWithString: "Ask first")
    private let chevronWell = ChatChevronWellView()
    private var popover: NSPopover?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        dot.modeProvider = { [weak self] in self?.mode ?? .askFirst }

        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.tx
        label.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [dot, label, chevronWell])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = (mode == .fullAccess
                              ? Theme.danger.withAlphaComponent(0.55)
                              : Theme.line2).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        showPopover()
    }

    func cycle() {
        let next = mode.next
        mode = next
        onModeChange?(next)
    }

    func showPopover() {
        popover?.close()
        let controller = ChatPermissionModePopoverController(current: mode) { [weak self] picked in
            self?.popover?.close()
            guard let self, picked != self.mode else { return }
            self.mode = picked
            self.onModeChange?(picked)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}

private final class ChatPermissionDotView: NSView {
    var modeProvider: () -> ChatPermissionMode = { .askFirst }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        modeProvider().dotColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// 16×18 accent rounded well with stacked up/down chevrons (pop-up affordance).
final class ChatChevronWellView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 18) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.acc.cgColor }
}

// MARK: - Popover

/// "PERMISSION MODE" list: dot + label + description rows, check on current,
/// footer "Cycle modes ⇧⇥". Plan is shown but disabled ("Requires backend
/// support").
final class ChatPermissionModePopoverController: NSViewController {
    private let current: ChatPermissionMode
    private let onPick: (ChatPermissionMode) -> Void

    init(current: ChatPermissionMode, onPick: @escaping (ChatPermissionMode) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 8, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false

        let title = SectionLabelField("Permission mode")
        column.addArrangedSubview(title)
        column.setCustomSpacing(7, after: title)

        for mode in ChatPermissionMode.allCases {
            let row = ChatPermissionModeRow(
                mode: mode,
                isCurrent: mode == current,
                onPick: { [onPick] in onPick(mode) })
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
        }

        let rule = ChatHairlineView()
        column.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
        column.setCustomSpacing(6, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])

        let footerLabel = NSTextField(labelWithString: "Cycle modes")
        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = Theme.tx3
        let key = NSTextField(labelWithString: "⇧⇥")
        key.font = NSFont.systemFont(ofSize: 10.5)
        key.textColor = Theme.tx3
        key.wantsLayer = true
        key.layer?.borderWidth = 1
        key.layer?.borderColor = Theme.line2.cgColor
        key.layer?.cornerRadius = 5
        let footer = NSStackView(views: [footerLabel, NSView(), key])
        footer.orientation = .horizontal
        footer.spacing = 6
        column.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -22).isActive = true

        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 290),
        ])
        view = container
    }
}

private final class ChatPermissionModeRow: NSControl {
    private let mode: ChatPermissionMode
    private let onPick: () -> Void

    init(mode: ChatPermissionMode, isCurrent: Bool, onPick: @escaping () -> Void) {
        self.mode = mode
        self.onPick = onPick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = mode.dotColor
            .withAlphaComponent(mode.isSelectable ? 1 : 0.5).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let name = NSTextField(labelWithString: mode.label)
        name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        name.textColor = mode.isSelectable ? Theme.tx : Theme.tx3

        let detail = ChatWrappingLabel(text: mode.detail, size: 11.5, color: Theme.tx3)
        detail.isSelectable = false

        let textColumn = NSStackView(views: [name, detail])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1

        if !mode.isSelectable {
            let unsupported = NSTextField(labelWithString: "Requires backend support")
            unsupported.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            unsupported.textColor = Theme.tx3
            textColumn.addArrangedSubview(unsupported)
        }

        let check = NSTextField(labelWithString: isCurrent ? "✓" : "")
        check.font = NSFont.systemFont(ofSize: 13)
        check.textColor = Theme.acc
        check.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let dotWrap = NSView()
        dotWrap.translatesAutoresizingMaskIntoConstraints = false
        dotWrap.addSubview(dot)
        NSLayoutConstraint.activate([
            dotWrap.widthAnchor.constraint(equalToConstant: 8),
            dot.topAnchor.constraint(equalTo: dotWrap.topAnchor, constant: 5),
            dot.leadingAnchor.constraint(equalTo: dotWrap.leadingAnchor),
            dot.bottomAnchor.constraint(lessThanOrEqualTo: dotWrap.bottomAnchor),
        ])

        let row = NSStackView(views: [dotWrap, textColumn, check])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        if isCurrent {
            layer?.backgroundColor = Theme.accSoft.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        guard mode.isSelectable else { return }
        onPick()
    }
}
