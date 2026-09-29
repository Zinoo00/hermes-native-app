import AppKit
import Combine

/// Automations sidebar: SCHEDULES group with All / Active / Paused single-select
/// filter rows (dot + label + live count from store.cronJobs) and the shared
/// workspace footer pinned to the bottom.
final class AutomationsSidebarViewController: NSViewController {

    private let store = AppEnvironment.shared.store
    private var cancellables = Set<AnyCancellable>()
    private var rows: [AutomationsFilterRow] = []

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = SectionLabelField("Schedules")

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 1
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        for filter in AutomationsFilter.allCases {
            let row = AutomationsFilterRow(filter: filter)
            row.onSelect = { AutomationsFilterState.shared.selection.send(filter) }
            rows.append(row)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        let footer = SidebarFooterView(store: store)

        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(rowsStack)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            // Pin below the titlebar/traffic-lights (safe area), matching the
            // Chat/Skills sidebars — view.topAnchor would tuck under the lights.
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            rowsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        bind()
    }

    private func bind() {
        store.$cronJobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in self?.updateCounts(jobs) }
            .store(in: &cancellables)

        AutomationsFilterState.shared.selection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selected in
                self?.rows.forEach { $0.isSelectedRow = ($0.filter == selected) }
            }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.rows.forEach { $0.refreshColors() }
        }
    }

    private func updateCounts(_ jobs: [CronJob]) {
        for row in rows {
            row.count = jobs.filter { row.filter.matches($0) }.count
        }
    }
}

/// One whole-row-clickable filter row: status dot + label + trailing count.
/// Selected state = accent-soft wash (design automations sidebar).
final class AutomationsFilterRow: NSControl {

    let filter: AutomationsFilter
    var onSelect: (() -> Void)?

    var count: Int = 0 {
        didSet { countLabel.stringValue = "\(count)" }
    }

    var isSelectedRow = false {
        didSet { refreshColors() }
    }

    private let dot = AutomationsDotView()
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField.label("0", size: 11.5, color: Theme.tx3)

    init(filter: AutomationsFilter) {
        self.filter = filter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        switch filter {
        case .all: dot.color = Theme.tx2
        case .active: dot.color = Theme.ok
        case .paused: dot.color = Theme.tx3
        }

        label.stringValue = filter.title
        label.font = Theme.bodyFont
        label.textColor = Theme.tx

        let row = NSStackView(views: [dot, label, NSView(), countLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func refreshColors() {
        let background: NSColor = isSelectedRow ? Theme.accSoft : .clear
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.layer?.backgroundColor = background.cgColor
        }
        dot.needsDisplay = true
    }
}

/// 7pt status dot used by the filter rows.
final class AutomationsDotView: NSView {
    var color: NSColor = Theme.tx2 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
