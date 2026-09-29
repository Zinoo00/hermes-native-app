import AppKit
import Combine

// Building blocks for the Settings content pane: inset-grouped cards of rows
// (title + subtitle left, value + › right or a custom accessory), plus the
// Appearance accent-swatch strip.

/// Configuration for one settings row.
struct SettingsRowConfig {
    var title: String
    var subtitle: String
    var value: String
    /// Custom trailing view (segmented control, swatches) replaces value+chevron.
    var accessory: NSView?
    var action: (() -> Void)?

    init(title: String, subtitle: String, value: String = "",
         accessory: NSView? = nil,
         action: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.accessory = accessory
        self.action = action
    }
}

/// One grouped-card row: 15/18 padding, hover wash when actionable.
final class SettingsRowView: NSView {

    private let action: (() -> Void)?
    private var hovering = false

    init(config: SettingsRowConfig) {
        action = config.action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let title = NSTextField.label(config.title, size: 14, color: Theme.tx)

        let subtitle = NSTextField(labelWithString: config.subtitle)
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = Theme.tx3
        subtitle.lineBreakMode = .byTruncatingTail

        let leftColumn = NSStackView(views: [title, subtitle])
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 2

        let right: NSView
        if let accessory = config.accessory {
            right = accessory
        } else {
            let value = NSTextField(labelWithString: config.value)
            value.font = NSFont.systemFont(ofSize: 13)
            value.textColor = Theme.tx2
            value.lineBreakMode = .byTruncatingTail
            value.alignment = .right

            let chevron = NSTextField(labelWithString: "›")
            chevron.font = NSFont.systemFont(ofSize: 12)
            chevron.textColor = Theme.tx3
            chevron.isHidden = config.action == nil

            let pair = NSStackView(views: [value, chevron])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 8
            right = pair
        }

        let row = NSStackView(views: [leftColumn, NSView(), right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 15, left: 18, bottom: 15, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)

        if action != nil {
            let tracking = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(tracking)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = hovering ? Theme.bgHover.cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if let action {
            action()
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Inset-grouped card: bg-raised, hairline border, radius 12; rows separated
/// by hairlines.
final class SettingsGroupCard: NSView {

    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pin(to: self)

        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if index < rows.count - 1 {
                let line = HairlineView()
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.line.cgColor
    }
}

// MARK: - Accent swatches (Appearance)

/// Six 20pt round swatches; the current accent shows an outer ring + white ✓.
final class AccentSwatchesView: NSView {

    private var buttons: [AccentSwatchButton] = []
    private var cancellable: AnyCancellable?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)

        for choice in AccentChoice.allCases {
            let button = AccentSwatchButton(choice: choice)
            button.isSelectedSwatch = (Theme.shared.accent == choice)
            buttons.append(button)
            row.addArrangedSubview(button)
        }

        cancellable = Theme.shared.accentPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current in
                self?.buttons.forEach { $0.isSelectedSwatch = ($0.choice == current) }
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class AccentSwatchButton: NSControl {

    let choice: AccentChoice

    var isSelectedSwatch = false {
        didSet { needsDisplay = true }
    }

    init(choice: AccentChoice) {
        self.choice = choice
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = choice.displayName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.isDark
        let color = NSColor(hex: isDark ? choice.darkHex : choice.lightHex)

        let circleRect = NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        if isSelectedSwatch {
            let ringRect = circleRect.insetBy(dx: -2.5, dy: -2.5)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            color.setStroke()
            ring.stroke()

            let check = NSAttributedString(string: "✓", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            let size = check.size()
            check.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                   y: bounds.midY - size.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        Theme.shared.accent = choice
    }
}
