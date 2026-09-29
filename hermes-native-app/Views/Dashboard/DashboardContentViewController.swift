//
//  DashboardContentViewController.swift
//  hermes-native-app
//
//  Dashboard (Overview) content: header, NEEDS ATTENTION queue (live
//  approval/clarify/… interactions aggregated across sessions), and the
//  ACTIVITY calendar day view synthesized from real sessions + cron jobs.
//

import AppKit
import Combine

final class DashboardContentViewController: NSViewController {
    private let store = AppEnvironment.shared.store
    private let model = DashboardModel.shared
    private var cancellables = Set<AnyCancellable>()

    /// Expanded attention cards survive re-renders.
    private var expandedAttention = Set<UUID>()

    // Header
    private let headerDateLabel = NSTextField(labelWithString: "")

    // Needs attention
    private let attentionCountChip = DashboardAccentChip(text: "0", fontSize: 11, cornerRadius: 8)
    private let attentionStack = NSStackView()

    // Activity calendar
    private let prevDayButton = NSButton()
    private let nextDayButton = NSButton()
    private let dayNavLabel = NSTextField(labelWithString: "Today")
    private let bigDateLabel = NSTextField(labelWithString: "")
    private let bigYearLabel = NSTextField(labelWithString: "")
    private let weekdayLabel = NSTextField(labelWithString: "")
    private let allDayContainer = NSStackView()
    private let allDayStack = NSStackView()
    private let hoursStack = NSStackView()
    private let calendarEmptyLabel = NSTextField(labelWithString: "")

    // MARK: View construction

    override func loadView() {
        let root = DashboardBackgroundView()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        scroll.pin(to: root)
        column.pin(to: document, insets: NSEdgeInsets(top: 26, left: 36, bottom: 70, right: 36))
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        buildHeader(in: column)
        buildAttentionSection(in: column)
        buildActivitySection(in: column)

        view = root
    }

    private func buildHeader(in column: NSStackView) {
        let title = NSTextField.label("Dashboard", size: 26, weight: .bold, color: Theme.tx)

        let subtitle = NSTextField.label("Here's what Hermes handled while you were away.", size: 13, color: Theme.tx3)

        let titleBlock = NSStackView(views: [title, subtitle])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 3

        headerDateLabel.font = NSFont.systemFont(ofSize: 12.5)
        headerDateLabel.textColor = Theme.tx3
        headerDateLabel.stringValue = DashboardFormat.headerDate.string(from: Date())

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [titleBlock, spacer, headerDateLabel])
        header.orientation = .horizontal
        header.alignment = .bottom
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(26, after: header)
    }

    private func buildAttentionSection(in column: NSStackView) {
        let heading = NSTextField(labelWithString: "Needs attention")
        heading.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = Theme.tx

        let headerRow = NSStackView(views: [heading, attentionCountChip])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 9
        column.addArrangedSubview(headerRow)
        column.setCustomSpacing(13, after: headerRow)

        attentionStack.orientation = .vertical
        attentionStack.alignment = .leading
        attentionStack.spacing = 9
        column.addArrangedSubview(attentionStack)
        attentionStack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(34, after: attentionStack)
    }

    private func buildActivitySection(in column: NSStackView) {
        // Eyebrow + day nav
        let eyebrow = SectionLabelField("Activity")

        prevDayButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous day")
        prevDayButton.isBordered = false
        prevDayButton.bezelStyle = .regularSquare
        prevDayButton.contentTintColor = Theme.tx2
        prevDayButton.target = self
        prevDayButton.action = #selector(goPreviousDay)

        nextDayButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next day")
        nextDayButton.isBordered = false
        nextDayButton.bezelStyle = .regularSquare
        nextDayButton.contentTintColor = Theme.tx2
        nextDayButton.target = self
        nextDayButton.action = #selector(goNextDay)

        dayNavLabel.font = NSFont.systemFont(ofSize: 12)
        dayNavLabel.textColor = Theme.tx2
        dayNavLabel.alignment = .center
        dayNavLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let navRow = NSStackView(views: [eyebrow, spacer, prevDayButton, dayNavLabel, nextDayButton])
        navRow.orientation = .horizontal
        navRow.alignment = .centerY
        navRow.spacing = 10
        column.addArrangedSubview(navRow)
        navRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(14, after: navRow)

        // Big date header
        bigDateLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        bigDateLabel.textColor = Theme.tx
        bigYearLabel.font = NSFont.systemFont(ofSize: 26, weight: .regular)
        bigYearLabel.textColor = Theme.tx3

        let dateRow = NSStackView(views: [bigDateLabel, bigYearLabel])
        dateRow.orientation = .horizontal
        dateRow.alignment = .firstBaseline
        dateRow.spacing = 7
        column.addArrangedSubview(dateRow)
        column.setCustomSpacing(2, after: dateRow)

        weekdayLabel.font = NSFont.systemFont(ofSize: 15)
        weekdayLabel.textColor = Theme.tx2
        column.addArrangedSubview(weekdayLabel)
        column.setCustomSpacing(16, after: weekdayLabel)

        // all-day row
        let allDayLabel = NSTextField.label("all-day", size: 11, weight: .semibold, color: Theme.tx3)
        allDayLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true

        allDayStack.orientation = .vertical
        allDayStack.alignment = .leading
        allDayStack.spacing = 5

        allDayContainer.orientation = .horizontal
        allDayContainer.alignment = .top
        allDayContainer.spacing = 0
        allDayContainer.addArrangedSubview(allDayLabel)
        allDayContainer.addArrangedSubview(allDayStack)
        column.addArrangedSubview(allDayContainer)
        allDayContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        allDayStack.widthAnchor.constraint(equalTo: allDayContainer.widthAnchor, constant: -54).isActive = true
        column.setCustomSpacing(6, after: allDayContainer)

        // hour rail
        hoursStack.orientation = .vertical
        hoursStack.alignment = .leading
        hoursStack.spacing = 0
        column.addArrangedSubview(hoursStack)
        hoursStack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        calendarEmptyLabel.font = NSFont.systemFont(ofSize: 12.5)
        calendarEmptyLabel.textColor = Theme.tx3
        calendarEmptyLabel.alignment = .center
        column.addArrangedSubview(calendarEmptyLabel)
        calendarEmptyLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    // MARK: Lifecycle / bindings

    override func viewDidLoad() {
        super.viewDidLoad()

        store.$attentionItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderAttention() }
            .store(in: &cancellables)

        // Session titles resolve attention card names once a chat is focused.
        store.$focusedSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderAttention() }
            .store(in: &cancellables)

        model.$events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderCalendar() }
            .store(in: &cancellables)

        model.$selectedDay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderCalendar() }
            .store(in: &cancellables)

        model.$selectedStatuses
            .combineLatest(model.$selectedActivities, model.$selectedPlatforms)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.renderAttention()
                self?.renderCalendar()
            }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.renderAttention()
            self?.renderCalendar()
        }

        renderAttention()
        renderCalendar()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        headerDateLabel.stringValue = DashboardFormat.headerDate.string(from: Date())
        // Data may be stale after time away in other sections.
        Task {
            await store.refreshSessions()
            await store.refreshCronJobs()
        }
    }

    // MARK: Needs attention

    private func renderAttention() {
        let visible = store.attentionItems.filter { model.isAttentionVisible($0) }
        expandedAttention.formIntersection(visible.map(\.id))

        attentionCountChip.text = "\(visible.count)"
        attentionCountChip.refreshAccent()
        attentionCountChip.isHidden = visible.isEmpty

        attentionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !visible.isEmpty else {
            let empty = makeAllCaughtUpCard()
            attentionStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: attentionStack.widthAnchor).isActive = true
            return
        }

        for item in visible {
            let card = AttentionCardView(
                item: item,
                sessionName: model.sessionName(for: item),
                expanded: expandedAttention.contains(item.id),
                store: store
            )
            card.onToggle = { [weak self] card in
                guard let self else { return }
                if self.expandedAttention.contains(card.itemID) {
                    self.expandedAttention.remove(card.itemID)
                    card.setExpanded(false)
                } else {
                    self.expandedAttention.insert(card.itemID)
                    card.setExpanded(true)
                }
            }
            attentionStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: attentionStack.widthAnchor).isActive = true
        }
    }

    /// Empty state: green check circle + "You're all caught up".
    private func makeAllCaughtUpCard() -> NSView {
        let card = DashboardRaisedCard()

        let circle = DashboardCheckCircleView()

        let title = NSTextField.label("You're all caught up", size: 14, weight: .medium, color: Theme.tx)

        let sub = NSTextField(labelWithString: "No approvals or failures waiting. Hermes surfaces anything urgent here.")
        sub.font = NSFont.systemFont(ofSize: 12.5)
        sub.textColor = Theme.tx3
        sub.lineBreakMode = .byTruncatingTail

        let textBlock = NSStackView(views: [title, sub])
        textBlock.orientation = .vertical
        textBlock.alignment = .leading
        textBlock.spacing = 1

        let row = NSStackView(views: [circle, textBlock])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.edgeInsets = NSEdgeInsets(top: 17, left: 18, bottom: 17, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        row.pin(to: card)
        return card
    }

    // MARK: Activity calendar

    @objc private func goPreviousDay() { model.stepDay(forward: false) }
    @objc private func goNextDay() { model.stepDay(forward: true) }

    private func renderCalendar() {
        let calendar = Calendar.current
        let day = model.selectedDay

        if calendar.isDateInToday(day) {
            dayNavLabel.stringValue = "Today"
        } else if calendar.isDateInYesterday(day) {
            dayNavLabel.stringValue = "Yesterday"
        } else if calendar.isDateInTomorrow(day) {
            dayNavLabel.stringValue = "Tomorrow"
        } else {
            dayNavLabel.stringValue = DashboardFormat.navDay.string(from: day)
        }

        let hasPrevious = model.previousDay != nil
        let hasNext = model.nextDay != nil
        prevDayButton.isEnabled = hasPrevious
        prevDayButton.alphaValue = hasPrevious ? 1 : 0.35
        nextDayButton.isEnabled = hasNext
        nextDayButton.alphaValue = hasNext ? 1 : 0.35

        bigDateLabel.stringValue = DashboardFormat.bigDate.string(from: day)
        bigYearLabel.stringValue = DashboardFormat.year.string(from: day)
        weekdayLabel.stringValue = DashboardFormat.weekday.string(from: day)

        let events = model.filteredEvents(on: day)
        let allDay = events.filter(\.isAllDay).sorted { $0.date < $1.date }
        let timed = events.filter { !$0.isAllDay }.sorted { $0.date < $1.date }

        // all-day row (cron runs / scheduled runs)
        allDayStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        allDayContainer.isHidden = allDay.isEmpty
        for event in allDay {
            let block = DashboardEventBlockView(event: event, allDay: true, onOpen: nil)
            allDayStack.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: allDayStack.widthAnchor).isActive = true
        }

        // hour rail: (first event − 1h) … (last event + 1h)
        hoursStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hoursStack.isHidden = timed.isEmpty
        if let first = timed.first, let last = timed.last {
            let firstHour = calendar.component(.hour, from: first.date)
            let lastHour = calendar.component(.hour, from: last.date)
            let lo = max(0, firstHour - 1)
            let hi = min(23, lastHour + 1)
            for hour in lo...hi {
                let hourEvents = timed.filter { calendar.component(.hour, from: $0.date) == hour }
                let row = DashboardHourRowView(hour: hour, events: hourEvents) { [weak self] event in
                    self?.open(event)
                }
                hoursStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: hoursStack.widthAnchor).isActive = true
            }
        }

        let isEmpty = allDay.isEmpty && timed.isEmpty
        calendarEmptyLabel.isHidden = !isEmpty
        calendarEmptyLabel.stringValue = model.hasActiveFilters
            ? "No activity matches this filter."
            : "No activity recorded for this day."
    }

    /// Click a session event -> jump to the conversation in Chat.
    private func open(_ event: DashboardEvent) {
        guard let storedID = event.sessionID else { return }
        (NSApp.delegate as? AppDelegate)?.coordinator.navigate(to: .chat)
        let store = store
        Task { await store.selectSession(storedID: storedID) }
    }
}

// MARK: - Local pieces

/// Content pane background (Theme.bg).
private final class DashboardBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.bg.cgColor }
}

/// Raised rounded card (bgRaised + hairline border).
private final class DashboardRaisedCard: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.line.cgColor
    }
}

/// 28pt green check circle for the all-caught-up state.
private final class DashboardCheckCircleView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        check.contentTintColor = Theme.ok
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        constrainSize(NSSize(width: 28, height: 28))
        check.center(in: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = DashboardColors.okSoft.cgColor }
}
