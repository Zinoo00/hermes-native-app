import AppKit

// Table pieces for the chat sidebar: custom row view (solid-accent rounded
// selection) plus the conversation / group-header / status cell views.

enum ChatSidebarMetrics {
    static let headerRowHeight: CGFloat = 30
    static let sessionRowHeight: CGFloat = 46
    static let statusRowHeight: CGFloat = 56
    static let rowCornerRadius: CGFloat = 6
    /// Vertical inset of the selection capsule — adjacent selections keep a
    /// 2pt gap (design: rows never touch).
    static let selectionGap: CGFloat = 1
}

/// Row view drawing the source-list selection as a full-width solid accent
/// rounded rect (design: selected conversation row). Propagates selection to
/// the cell so all row content flips to white.
final class ChatSidebarRowView: NSTableRowView {

    override var isEmphasized: Bool {
        get { true } // accent stays solid even when the sidebar loses focus
        set { _ = newValue }
    }

    override var isSelected: Bool {
        didSet { conversationCell?.isRowSelected = isSelected }
    }

    private var conversationCell: ConversationCellView? {
        subviews.compactMap { $0 as? ConversationCellView }.first
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ConversationCellView)?.isRowSelected = isSelected
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 0, dy: ChatSidebarMetrics.selectionGap)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: ChatSidebarMetrics.rowCornerRadius,
            yRadius: ChatSidebarMetrics.rowCornerRadius
        )
        Theme.acc.setFill()
        path.fill()
    }
}

/// Conversation row: optional pin glyph, title over subtitle, trailing
/// monochrome platform chip. Selected state renders everything white.
final class ConversationCellView: NSView {

    private let pinIcon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let chip = MonogramChipView(letter: "›")
    private let selectedChip = SelectedMonogramChipView()

    private var entry: ChatSidebarEntry?

    var isRowSelected = false {
        didSet { applyColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pinIcon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        pinIcon.setContentHuggingPriority(.required, for: .horizontal)
        pinIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.maximumNumberOfLines = 1

        subtitleField.font = NSFont.systemFont(ofSize: 11)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.usesSingleLineMode = true
        subtitleField.maximumNumberOfLines = 1

        for field in [titleField, subtitleField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let textColumn = NSStackView(views: [titleField, subtitleField])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1

        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        selectedChip.setContentHuggingPriority(.required, for: .horizontal)
        selectedChip.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Chips overlap in one slot; selection toggles which is visible
        // (shared MonogramChipView has fixed neutral colors by design).
        let chipSlot = NSView()
        chipSlot.translatesAutoresizingMaskIntoConstraints = false
        for chipView in [chip, selectedChip] {
            chipSlot.addSubview(chipView)
            chipView.pin(to: chipSlot)
        }

        let row = NSStackView(views: [pinIcon, textColumn, chipSlot])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with entry: ChatSidebarEntry) {
        self.entry = entry
        titleField.stringValue = entry.title
        subtitleField.stringValue = entry.subtitle
        subtitleField.isHidden = entry.subtitle.isEmpty
        chip.letter = entry.glyph
        selectedChip.letter = entry.glyph
        toolTip = nil
        chip.toolTip = entry.chipTooltip
        selectedChip.toolTip = entry.chipTooltip
        pinIcon.isHidden = !entry.pinned
        applyColors()
    }

    private func applyColors() {
        if isRowSelected {
            titleField.textColor = .white
            subtitleField.textColor = NSColor.white.withAlphaComponent(0.82)
            pinIcon.contentTintColor = .white
        } else {
            titleField.textColor = Theme.tx
            subtitleField.textColor = Theme.tx3
            pinIcon.contentTintColor = Theme.acc
        }
        chip.isHidden = isRowSelected
        selectedChip.isHidden = !isRowSelected
    }
}

/// White-on-translucent monogram chip shown while its row is selected
/// (design: chip bg rgba(255,255,255,.25), glyph white).
final class SelectedMonogramChipView: NSView {
    var letter: String = "›" {
        didSet { label.stringValue = String(letter.prefix(1)) }
    }

    private let label = NSTextField(labelWithString: "›")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        layer?.cornerRadius = 5

        label.font = Theme.monoFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        label.center(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }
}

/// TODAY / YESTERDAY / … group header cell.
final class ChatSidebarHeaderCellView: NSView {
    private let label = SectionLabelField("")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String) {
        label.stringValue = title
    }
}

/// Quiet centered message row, optionally with a small spinner
/// ("Starting Hermes…" while connecting; empty states when idle).
final class ChatSidebarStatusCellView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        label.font = NSFont.systemFont(ofSize: 12.5)
        label.textColor = Theme.tx3
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, spinner showsSpinner: Bool) {
        label.stringValue = text
        if showsSpinner {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }
}
