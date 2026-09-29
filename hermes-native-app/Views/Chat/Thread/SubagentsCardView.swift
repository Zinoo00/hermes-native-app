import AppKit

/// SUBAGENTS card: uppercase header + "· N running in parallel", rows of
/// accent dot + name + detail + slim accent progress bar. Bound to
/// `ChatSession.subagents`; hidden by the transcript view when empty.
final class ChatSubagentsCardView: ChatCardView {

    private let headerLabel = SectionLabelField("Subagents")
    private let headerDetail = NSTextField.label(size: 11, color: Theme.tx3)
    private let rowsStack = NSStackView()
    private var rowViews: [String: ChatSubagentRowView] = [:]

    init() {
        super.init(fill: { Theme.bgRaised }, stroke: { Theme.line }, radius: 12)

        let header = NSStackView(views: [headerLabel, headerDetail])
        header.orientation = .horizontal
        header.spacing = 8

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10

        let column = NSStackView(views: [header, rowsStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        column.pin(to: self, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        rowsStack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    func update(rows: [SubagentRow]) {
        let running = rows.filter { !$0.isFinished }.count
        if running > 0 {
            headerDetail.stringValue = running == 1
                ? "· 1 running" : "· \(running) running in parallel"
        } else {
            headerDetail.stringValue = "· done"
        }

        var seen = Set<String>()
        for (index, row) in rows.enumerated() {
            seen.insert(row.id)
            let view: ChatSubagentRowView
            if let existing = rowViews[row.id] {
                view = existing
            } else {
                view = ChatSubagentRowView()
                rowViews[row.id] = view
            }
            view.update(row)
            if index < rowsStack.arrangedSubviews.count {
                if rowsStack.arrangedSubviews[index] !== view {
                    view.removeFromSuperview()
                    rowsStack.insertArrangedSubview(view, at: index)
                    view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                }
            } else {
                rowsStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
        for (id, view) in rowViews where !seen.contains(id) {
            view.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }
    }
}

/// dot · name (fixed column) · detail (flexible) · 56×4 accent bar.
final class ChatSubagentRowView: NSView {
    private let dot = ChatSubagentDotView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = ChatSubagentBarView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = Theme.tx
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true

        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = Theme.tx2
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bar.constrainSize(NSSize(width: 56, height: 4))

        let row = NSStackView(views: [dot, nameLabel, detailLabel, bar])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ row: SubagentRow) {
        let goal = row.goal.isEmpty ? "subagent \(row.taskIndex + 1)" : row.goal
        nameLabel.stringValue = goal
        var detail = row.detail ?? ""
        if detail.isEmpty { detail = row.status }
        detailLabel.stringValue = detail.replacingOccurrences(of: "\n", with: " ")

        dot.isFinished = row.isFinished
        bar.fraction = row.isFinished ? 1.0 : fraction(for: row.status)
    }

    private func fraction(for status: String) -> CGFloat {
        switch status {
        case "queued": return 0.12
        case "thinking": return 0.35
        default: return status.hasPrefix("tool") ? 0.65 : 0.5
        }
    }
}

/// 8pt dot: accent while running (pulses), ok-green when finished.
private final class ChatSubagentDotView: NSView {
    var isFinished = false {
        didSet {
            if isFinished != oldValue { needsDisplay = true; updatePulse() }
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        (isFinished ? Theme.ok : Theme.acc).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    private func updatePulse() {
        layer?.removeAnimation(forKey: "chat.pulse")
        // Hold a steady dot when Reduce Motion is on; otherwise a calm pulse.
        guard !isFinished, window != nil, !Motion.reduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "chat.pulse")
    }
}

/// 4pt rounded track with accent fill fraction.
private final class ChatSubagentBarView: NSView {
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
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard fraction > 0 else { return }
        var fillRect = bounds
        fillRect.size.width = max(4, bounds.width * min(fraction, 1))
        (fraction >= 1 ? Theme.ok : Theme.acc).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
    }
}
