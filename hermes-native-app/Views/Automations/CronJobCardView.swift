import AppKit

/// One automation card (design: full-width bg-raised card, radius 12):
///   row 1 — name + status tag + trailing NSSwitch
///   row 2 — human schedule + mono cron chip + "→ deliver" pill
///   row 3 — "Next run · …"
/// Context menu: Run now / Pause·Resume / Edit… / Delete.
final class CronJobCardView: NSView {

    var onToggleEnabled: ((Bool) -> Void)?
    var onRunNow: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private let scheduleLabel = NSTextField(labelWithString: "")
    private let cronChip = CronChipView(style: .mono)
    private let deliverChip = CronChipView(style: .pill)
    private let nextRunLabel = NSTextField.label(size: 11.5, color: Theme.tx3)
    private var jobEnabled = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .medium)
        titleLabel.textColor = Theme.tx
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(switchChanged(_:))

        let topRow = NSStackView(views: [titleLabel, statusLabel, NSView(), toggle])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 12

        scheduleLabel.font = NSFont.systemFont(ofSize: 12.5)
        scheduleLabel.textColor = Theme.tx2
        scheduleLabel.lineBreakMode = .byTruncatingTail

        let midRow = NSStackView(views: [scheduleLabel, cronChip, deliverChip, NSView()])
        midRow.orientation = .horizontal
        midRow.alignment = .centerY
        midRow.spacing = 9

        let column = NSStackView(views: [topRow, midRow, nextRunLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 15, left: 18, bottom: 15, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
            midRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.line.cgColor
    }

    // MARK: Configure

    func configure(with job: CronJob) {
        jobEnabled = job.enabled
        titleLabel.stringValue = job.name.isEmpty ? job.id : job.name

        let paused = !job.enabled || job.state == "paused"
        if paused {
            statusLabel.stringValue = "Paused"
            statusLabel.textColor = Theme.tx3
        } else if job.lastStatus == "error" || job.state == "error" {
            let detail = (job.lastError?.isEmpty == false) ? job.lastError! : "flagged last run"
            statusLabel.stringValue = "⚠ \(detail)"
            statusLabel.textColor = Theme.danger
        } else if job.lastStatus == "ok" {
            statusLabel.stringValue = "✓ last run ok"
            statusLabel.textColor = Theme.ok
        } else {
            // Never run yet — quiet neutral tag (design defines only the three states above).
            statusLabel.stringValue = "Scheduled"
            statusLabel.textColor = Theme.tx3
        }

        toggle.state = job.enabled ? .on : .off

        scheduleLabel.stringValue = CronFormat.humanSchedule(for: job)

        if job.scheduleKind == "cron", let expr = job.scheduleExpression, !expr.isEmpty {
            cronChip.text = expr
            cronChip.isHidden = false
        } else {
            cronChip.isHidden = true
        }

        if let deliver = job.deliver, !deliver.isEmpty, deliver.lowercased() != "local" {
            deliverChip.text = "→ \(deliver.prefix(1).uppercased() + deliver.dropFirst())"
            deliverChip.isHidden = false
        } else {
            deliverChip.isHidden = true
        }

        nextRunLabel.stringValue = paused
            ? "Next run · Paused"
            : "Next run · \(CronFormat.nextRunText(job.nextRunAt))"

        menu = buildMenu()
    }

    // MARK: Actions

    @objc private func switchChanged(_ sender: NSSwitch) {
        onToggleEnabled?(sender.state == .on)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(title: "Run now", action: #selector(runNow(_:))))
        menu.addItem(makeItem(title: jobEnabled ? "Pause" : "Resume",
                              action: #selector(togglePause(_:))))
        menu.addItem(makeItem(title: "Edit schedule…", action: #selector(edit(_:))))
        menu.addItem(.separator())
        let delete = makeItem(title: "Delete", action: #selector(delete(_:)))
        delete.attributedTitle = NSAttributedString(
            string: "Delete",
            attributes: [.foregroundColor: Theme.danger, .font: Theme.bodyFont]
        )
        menu.addItem(delete)
        return menu
    }

    private func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func runNow(_ sender: Any?) { onRunNow?() }
    @objc private func togglePause(_ sender: Any?) { onToggleEnabled?(!jobEnabled) }
    @objc private func edit(_ sender: Any?) { onEdit?() }
    @objc private func delete(_ sender: Any?) { onDelete?() }
}

/// Small text chip: mono cron expression (inset square) or "→ target" pill.
final class CronChipView: NSView {
    enum Style { case mono, pill }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    private let label = NSTextField(labelWithString: "")
    private let style: Style

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        switch style {
        case .mono:
            layer?.cornerRadius = 5
            layer?.borderWidth = 1
            label.font = Theme.monoFont(ofSize: 11)
            label.textColor = Theme.tx
        case .pill:
            layer?.cornerRadius = 10
            label.font = NSFont.systemFont(ofSize: 11.5)
            label.textColor = Theme.tx2
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let horizontal: CGFloat = style == .mono ? 7 : 8
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontal),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontal),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgInset.cgColor
        if style == .mono {
            layer?.borderColor = Theme.line.cgColor
        }
    }
}
