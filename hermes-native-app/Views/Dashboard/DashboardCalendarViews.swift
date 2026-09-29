//
//  DashboardCalendarViews.swift
//  hermes-native-app
//
//  Building blocks for the ACTIVITY macOS-Calendar-style day view:
//  hour rows with a 54pt gutter and hairline top borders, and flat inset
//  event blocks with a 3px semantic left bar (accent = awaiting/running,
//  red = error, neutral otherwise).
//

import AppKit

// MARK: - Event block

/// Flat inset block used both in the all-day row (single line) and inside
/// hour rows (title line + clock/time line). Clicking a session-backed event
/// jumps to the conversation.
final class DashboardEventBlockView: NSControl {
    private let event: DashboardEvent
    private let onOpen: ((DashboardEvent) -> Void)?
    private let barView = DashboardBarView()
    private var isHovering = false

    init(event: DashboardEvent, allDay: Bool, onOpen: ((DashboardEvent) -> Void)?) {
        self.event = event
        self.onOpen = onOpen
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        barView.color = Self.barColor(for: event.outcome)
        barView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barView)
        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: leadingAnchor),
            barView.topAnchor.constraint(equalTo: topAnchor),
            barView.bottomAnchor.constraint(equalTo: bottomAnchor),
            barView.widthAnchor.constraint(equalToConstant: 3),
        ])

        if allDay {
            buildAllDayRow()
        } else {
            buildTimedRows()
        }

        if event.sessionID != nil, onOpen != nil {
            addTrackingHover()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func barColor(for outcome: DashboardEvent.Outcome) -> NSColor {
        switch outcome {
        case .awaiting: return Theme.acc
        case .flagged: return Theme.danger
        case .ok, .neutral: return DashboardColors.neutralBar
        }
    }

    // MARK: Layouts

    /// all-day: title ······ time ✓/⚠
    private func buildAllDayRow() {
        let title = NSTextField(labelWithString: event.title)
        title.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = Theme.tx
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let time = NSTextField(labelWithString: event.timeLabel)
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = barView.color

        var views: [NSView] = [title, spacer, time]
        if let outcomeIcon = makeOutcomeIcon() {
            views.append(outcomeIcon)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 0))
    }

    /// timed: title · platform tag · [Awaiting] over 🕓 time
    private func buildTimedRows() {
        let title = NSTextField(labelWithString: event.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.textColor = Theme.tx
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        var topViews: [NSView] = [title, spacer]
        if let sourceName = event.sourceName {
            topViews.append(makeSourceTag(sourceName))
        }
        if event.outcome == .awaiting {
            topViews.append(DashboardAccentChip(text: "Awaiting", fontSize: 10, cornerRadius: 5))
        }

        let topRow = NSStackView(views: topViews)
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        let clock = NSImageView()
        clock.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        clock.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        clock.contentTintColor = barView.color

        let time = NSTextField(labelWithString: event.timeLabel)
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = barView.color

        let timeRow = NSStackView(views: [clock, time])
        timeRow.orientation = .horizontal
        timeRow.alignment = .centerY
        timeRow.spacing = 5

        let column = NSStackView(views: [topRow, timeRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        column.pin(to: self, insets: NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 0))
        topRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
    }

    /// Monochrome dot + source name (platform identity stays neutral).
    private func makeSourceTag(_ name: String) -> NSView {
        let dot = DashboardDotView(color: Theme.tx3, diameter: 6)
        let label = NSTextField.label(name, size: 10.5, color: Theme.tx2)
        let tag = NSStackView(views: [dot, label])
        tag.orientation = .horizontal
        tag.alignment = .centerY
        tag.spacing = 5
        return tag
    }

    /// ✓ green when done, ⚠ red when flagged (all-day row only).
    private func makeOutcomeIcon() -> NSView? {
        let glyph: String
        let color: NSColor
        switch event.outcome {
        case .ok: glyph = "✓"; color = Theme.ok
        case .flagged: glyph = "⚠"; color = Theme.danger
        case .awaiting, .neutral: return nil
        }
        let label = NSTextField.label(glyph, size: 12, color: color)
        return label
    }

    // MARK: Hover + click

    private func addTrackingHover() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard self.event.sessionID != nil else { return }
        onOpen?(self.event)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isHovering ? Theme.bgHover : Theme.bgInset).cgColor
    }
}

// MARK: - Hour row

/// One hour of the rail: hairline top border, 54pt gutter label
/// ("7 PM" / "Noon"), stacked full-width event blocks, min height 46.
final class DashboardHourRowView: NSView {
    init(hour: Int, events: [DashboardEvent], onOpen: @escaping (DashboardEvent) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let hairline = HairlineView()
        addSubview(hairline)

        let label = NSTextField(labelWithString: "")
        let parts = DashboardFormat.hourLabel(hour)
        let text = NSMutableAttributedString(
            string: parts.main,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: Theme.tx2,
            ]
        )
        if !parts.suffix.isEmpty {
            text.append(NSAttributedString(
                string: " " + parts.suffix,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                    .foregroundColor: Theme.tx3,
                ]
            ))
        }
        label.attributedStringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let blocks = NSStackView()
        blocks.orientation = .vertical
        blocks.alignment = .leading
        blocks.spacing = 5
        blocks.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blocks)
        for event in events {
            let block = DashboardEventBlockView(event: event, allDay: false, onOpen: onOpen)
            blocks.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: blocks.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 54),
            blocks.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 54),
            blocks.trailingAnchor.constraint(equalTo: trailingAnchor),
            blocks.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            blocks.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Small shared pieces

/// Solid color bar/fill view (theme-aware via updateLayer).
final class DashboardBarView: NSView {
    var color: NSColor = DashboardColors.neutralBar { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}

/// Small round dot.
final class DashboardDotView: NSView {
    private let color: NSColor
    private let diameter: CGFloat

    init(color: NSColor, diameter: CGFloat) {
        self.color = color
        self.diameter = diameter
        super.init(frame: .zero)
        constrainSize(NSSize(width: diameter, height: diameter))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Accent-on-accent-wash pill ("Awaiting" badge, attention count chip).
final class DashboardAccentChip: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(text: String, fontSize: CGFloat, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = Theme.acc
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pin(to: self, insets: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Re-fetch accent (Theme.acc is user-overridable).
    func refreshAccent() {
        label.textColor = Theme.acc
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.accSoft.cgColor }
}
