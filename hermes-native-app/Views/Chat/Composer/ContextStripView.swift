import AppKit

/// Floats above the composer: removable @chips on the left, "CONTEXT ▓ 38K /
/// 200K" meter pill on the right (hidden while the backend hasn't reported
/// context usage).
final class ChatContextStripView: NSView {

    var onRemoveChip: ((ChatContextReference) -> Void)?

    private let chipsStack = NSStackView()
    private let meter = ChatContextMeterView()
    private var references: [ChatContextReference] = []
    private var meterVisible = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chipsStack.orientation = .horizontal
        chipsStack.alignment = .centerY
        chipsStack.spacing = 7
        chipsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [chipsStack, NSView(), meter])
        row.orientation = .horizontal
        row.alignment = .bottom
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setReferences(_ references: [ChatContextReference]) {
        self.references = references
        chipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for reference in references {
            let chip = ChatContextChipView(reference: reference) { [weak self] in
                self?.onRemoveChip?(reference)
            }
            chipsStack.addArrangedSubview(chip)
        }
        refreshVisibility()
    }

    func setUsage(contextUsed: Int?, contextMax: Int?) {
        if let used = contextUsed, let max = contextMax, max > 0 {
            meter.update(used: used, max: max)
            meterVisible = true
        } else {
            meterVisible = false
        }
        refreshVisibility()
    }

    private func refreshVisibility() {
        meter.isHidden = !meterVisible
        isHidden = references.isEmpty && !meterVisible
    }
}

/// Raised chip: mono accent "@" + mono label + × remove button.
final class ChatContextChipView: NSView {
    private let onRemove: () -> Void

    init(reference: ChatContextReference, onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        let at = NSTextField(labelWithString: "@")
        at.font = Theme.monoFont(ofSize: 11, weight: .semibold)
        at.textColor = Theme.acc

        let label = NSTextField(labelWithString: reference.label)
        label.font = Theme.monoFont(ofSize: 11)
        label.textColor = Theme.tx
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true

        let close = NSButton(title: "×", target: self, action: #selector(removeTapped))
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 13)
        close.contentTintColor = Theme.tx2
        close.setButtonType(.momentaryChange)

        let row = NSStackView(views: [at, label, close])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 27),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.acc.withAlphaComponent(0.4).cgColor
    }

    @objc private func removeTapped() {
        onRemove()
    }
}

/// "CONTEXT" label + 96×6 accent bar + "38K / 200K" value.
final class ChatContextMeterView: NSView {
    private let title = NSTextField(labelWithString: "CONTEXT")
    private let bar = ChatContextMeterBarView()
    private let value = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        title.textColor = Theme.tx3

        value.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = Theme.tx2

        bar.widthAnchor.constraint(equalToConstant: 96).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let row = NSStackView(views: [title, bar, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(used: Int, max: Int) {
        bar.fraction = max > 0 ? CGFloat(used) / CGFloat(max) : 0
        value.stringValue = "\(Self.compactTokens(used)) / \(Self.compactTokens(max))"
    }

    static func compactTokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return "\(Int((Double(count) / 1_000).rounded()))K"
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}

private final class ChatContextMeterBarView: NSView {
    var fraction: CGFloat = 0 {
        didSet { if abs(fraction - oldValue) > 0.001 { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bgInset2.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        guard fraction > 0 else { return }
        var fillRect = bounds
        fillRect.size.width = max(5, bounds.width * min(fraction, 1))
        Theme.acc.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
    }
}
