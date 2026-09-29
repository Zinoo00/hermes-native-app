import AppKit
import Combine

/// Shared sidebar footer pinned to the bottom of every workspace sidebar
/// (Chat / Dashboard / Skills / Automations; hidden in Settings).
/// Two flush collapsible sections separated by hairlines:
///   USAGE — spend summary + expandable token bar and cost breakdown
///   Hermes online — status dot + expandable backend facts
/// Self-contained: observes `HermesStore` and updates itself. Embed with
/// `SidebarFooterView(store:)`, pin to the sidebar's bottom edge.
final class SidebarFooterView: NSView {
    private let store: HermesStore
    private var cancellables = Set<AnyCancellable>()

    private let usageDisclosure = FooterDisclosureRow()
    private let usageBar = FooterBarView()
    private let usageCaption = NSTextField(labelWithString: "")
    private let usageDetail = NSStackView()
    private let statusDisclosure = FooterDisclosureRow()
    private let statusDot = PulseDotView()
    private let statusDetail = NSStackView()

    private var usageOpen = false { didSet { updateVisibility() } }
    private var statusOpen = false { didSet { updateVisibility() } }

    init(store: HermesStore) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        bind()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private let stack = NSStackView()

    private func buildUI() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let topRule = HairlineView()
        addSubview(topRule)
        topRule.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // — USAGE
        usageDisclosure.configure(title: "USAGE", detail: "")
        usageDisclosure.onToggle = { [weak self] in self?.usageOpen.toggle(); self?.usageDisclosure.setExpanded(self?.usageOpen ?? false) }
        stack.addArrangedSubview(usageDisclosure)
        usageDisclosure.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        stack.addArrangedSubview(usageBar)
        usageBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        usageBar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        usageCaption.font = NSFont.systemFont(ofSize: 10)
        usageCaption.textColor = Theme.tx3
        stack.addArrangedSubview(usageCaption)

        usageDetail.orientation = .vertical
        usageDetail.alignment = .leading
        usageDetail.spacing = 4
        stack.addArrangedSubview(usageDetail)
        usageDetail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let midRule = HairlineView()
        stack.addArrangedSubview(midRule)
        midRule.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        // — Hermes online
        let statusRow = NSStackView(views: [statusDot, statusDisclosure])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusDisclosure.configure(title: "Hermes offline", detail: "", uppercase: false)
        statusDisclosure.onToggle = { [weak self] in self?.statusOpen.toggle(); self?.statusDisclosure.setExpanded(self?.statusOpen ?? false) }
        stack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        statusDetail.orientation = .vertical
        statusDetail.alignment = .leading
        statusDetail.spacing = 5
        stack.addArrangedSubview(statusDetail)
        statusDetail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        updateVisibility()
    }

    private func updateVisibility() {
        usageCaption.isHidden = !usageOpen && usageCaption.stringValue.isEmpty
        usageDetail.isHidden = !usageOpen
        statusDetail.isHidden = !statusOpen
    }

    // MARK: Data

    private func bind() {
        store.$usageAnalytics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in self?.renderUsage(usage) }
            .store(in: &cancellables)

        store.$connectionState
            .combineLatest(store.$backendStatus, store.$focusedSession, store.$cronJobs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, status, session, jobs in
                self?.renderStatus(state: state, status: status, session: session, jobs: jobs)
            }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.usageBar.needsDisplay = true
        }
    }

    private func renderUsage(_ usage: AnalyticsUsage?) {
        var cost = usage?.totalActualCost ?? 0
        if cost == 0 { cost = usage?.totalEstimatedCost ?? 0 }
        let tokens = (usage?.totalInput ?? 0) + (usage?.totalOutput ?? 0)
        usageDisclosure.update(detail: cost > 0 ? String(format: "$%.2f", cost) : "—")
        // Design shows "$X / $Y monthly budget" — hermes has no budget concept;
        // the bar shows relative spend across the loaded window instead.
        usageBar.fraction = min(1, cost / 100)
        usageCaption.stringValue = usage == nil ? "" : "last 30 days"

        usageDetail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let usage else { return }
        usageDetail.addArrangedSubview(FooterFactRow.make(label: "Tokens", value: Self.compact(tokens)))
        usageDetail.addArrangedSubview(FooterFactRow.make(label: "Sessions", value: "\(usage.totalSessions)"))
        usageDetail.addArrangedSubview(FooterFactRow.make(label: "API calls", value: "\(usage.totalAPICalls)"))
    }

    private func renderStatus(state: HermesStore.ConnectionState, status: StatusResponse?, session: ChatSession?, jobs: [CronJob]) {
        let online = state.isReady
        statusDot.color = online ? Theme.ok : Theme.tx3
        switch state {
        case .idle: statusDisclosure.update(title: "Hermes idle")
        case .launching: statusDisclosure.update(title: "Hermes starting…")
        case .connecting: statusDisclosure.update(title: "Hermes connecting…")
        case .ready: statusDisclosure.update(title: "Hermes online")
        case .failed: statusDisclosure.update(title: "Hermes offline")
        }

        statusDetail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard online else { return }
        if let info = session?.info {
            var model = info.model
            if let effort = info.reasoningEffort, !effort.isEmpty { model += " · \(effort.capitalized)" }
            statusDetail.addArrangedSubview(FooterFactRow.make(label: "MODEL", value: model))
            let subagents = info.usage?.activeSubagents ?? 0
            if subagents > 0 {
                statusDetail.addArrangedSubview(FooterFactRow.make(label: "RUNNING", value: "\(subagents) subagents"))
            }
        } else if let version = status?.version {
            statusDetail.addArrangedSubview(FooterFactRow.make(label: "BACKEND", value: "v\(version)"))
        }
        if status?.gatewayRunning == true {
            statusDetail.addArrangedSubview(FooterFactRow.make(label: "GATEWAY", value: "running"))
        }
        if let next = jobs.filter({ $0.enabled }).compactMap({ job -> (String, Date)? in
            guard let raw = job.nextRunAt, let date = Self.isoFormatter.date(from: raw) else { return nil }
            return (job.name, date)
        }).min(by: { $0.1 < $1.1 }) {
            statusDetail.addArrangedSubview(FooterFactRow.make(label: "NEXT", value: "\(next.0) · \(Self.nextRunTimeFormatter.string(from: next.1))"))
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static let nextRunTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt
    }()

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}

// MARK: - Pieces

/// Header row: uppercase label + trailing detail + chevron; whole row clickable.
final class FooterDisclosureRow: NSControl {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleField.font = Theme.sectionLabelFont
        titleField.textColor = Theme.tx3
        detailField.font = NSFont.systemFont(ofSize: 11)
        detailField.textColor = Theme.tx2
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = Theme.tx3

        let row = NSStackView(views: [titleField, NSView(), detailField, chevron])
        row.orientation = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, detail: String, uppercase: Bool = true) {
        titleField.stringValue = uppercase ? title.uppercased() : title
        titleField.font = uppercase ? Theme.sectionLabelFont : NSFont.systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = uppercase ? Theme.tx3 : Theme.tx
        detailField.stringValue = detail
    }

    func update(title: String? = nil, detail: String? = nil) {
        if let title { titleField.stringValue = title }
        if let detail { detailField.stringValue = detail }
    }

    func setExpanded(_ expanded: Bool) {
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
}

/// 6pt rounded determinate bar, accent fill on inset track.
final class FooterBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        Theme.bgInset2.setFill()
        track.fill()
        guard fraction > 0 else { return }
        var fillRect = bounds
        fillRect.size.width = max(6, bounds.width * fraction)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
        Theme.acc.setFill()
        fill.fill()
    }
}

/// Small green pulsing status dot.
final class PulseDotView: NSView {
    var color: NSColor = Theme.ok { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

enum FooterFactRow {
    /// "LABEL        value" row matching the design's status facts.
    static func make(label: String, value: String) -> NSView {
        let l = NSTextField.label(label.uppercased(), size: 10, weight: .medium, color: Theme.tx3)
        let v = NSTextField(labelWithString: value)
        v.font = NSFont.systemFont(ofSize: 11)
        v.textColor = Theme.tx2
        v.lineBreakMode = .byTruncatingTail
        v.alignment = .right
        let row = NSStackView(views: [l, NSView(), v])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return row
    }
}
