import AppKit
import Combine

/// Automations content: header ("Automations" + blurb + "+ New schedule" link)
/// above a column of cron-job cards bound to store.cronJobs, filtered by the
/// sidebar's All/Active/Paused selection.
final class AutomationsContentViewController: NSViewController {

    private let store = AppEnvironment.shared.store
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let newScheduleButton = NSButton(title: "", target: nil, action: nil)
    private let cardsStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private var currentJobs: [CronJob] = []
    private var currentFilter: AutomationsFilter = .all

    override func loadView() {
        view = AutomationsBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bind()
    }

    // MARK: UI

    private func buildUI() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        view.addSubview(scrollView)
        scrollView.pin(to: view)

        let title = NSTextField.label("Automations", size: 20, weight: .semibold, color: Theme.tx)

        newScheduleButton.isBordered = false
        newScheduleButton.target = self
        newScheduleButton.action = #selector(newSchedule(_:))
        newScheduleButton.setButtonType(.momentaryChange)
        retintNewScheduleButton()

        let headerRow = NSStackView(views: [title, NSView(), newScheduleButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .lastBaseline
        headerRow.spacing = 12

        let blurb = NSTextField(wrappingLabelWithString:
            "Cron tasks described in natural language, running unattended and delivering to any platform.")
        blurb.font = Theme.bodyFont
        blurb.textColor = Theme.tx2

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 12

        emptyLabel.font = Theme.bodyFont
        emptyLabel.textColor = Theme.tx3
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let column = NSStackView(views: [headerRow, blurb, cardsStack, emptyLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.setCustomSpacing(22, after: blurb)
        column.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(column)
        documentView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            column.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            column.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 36),
            column.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -36),
            column.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -70),

            headerRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            blurb.widthAnchor.constraint(equalTo: column.widthAnchor),
            cardsStack.widthAnchor.constraint(equalTo: column.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private func retintNewScheduleButton() {
        newScheduleButton.attributedTitle = NSAttributedString(
            string: "+ New schedule",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: Theme.acc,
            ]
        )
    }

    // MARK: Bindings

    private func bind() {
        store.$cronJobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in
                self?.currentJobs = jobs
                self?.render()
            }
            .store(in: &cancellables)

        AutomationsFilterState.shared.selection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filter in
                self?.currentFilter = filter
                self?.render()
            }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.retintNewScheduleButton()
        }
    }

    private func render() {
        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let jobs = currentJobs.filter { currentFilter.matches($0) }

        if jobs.isEmpty {
            emptyLabel.isHidden = false
            switch currentFilter {
            case .all:
                emptyLabel.stringValue = store.connectionState.isReady
                    ? "No schedules yet. Create one with “+ New schedule”."
                    : "Waiting for the Hermes backend…"
            case .active:
                emptyLabel.stringValue = "No active schedules."
            case .paused:
                emptyLabel.stringValue = "No paused schedules."
            }
            return
        }

        emptyLabel.isHidden = true
        for job in jobs {
            let card = CronJobCardView()
            card.configure(with: job)
            card.onToggleEnabled = { [weak self] enabled in self?.setEnabled(job, enabled: enabled) }
            card.onRunNow = { [weak self] in self?.runNow(job) }
            card.onEdit = { [weak self] in self?.edit(job) }
            card.onDelete = { [weak self] in self?.confirmDelete(job) }
            cardsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
        }
    }

    // MARK: Actions

    @objc private func newSchedule(_ sender: Any?) {
        presentAsSheet(ScheduleEditorViewController(store: store, job: nil))
    }

    private func edit(_ job: CronJob) {
        presentAsSheet(ScheduleEditorViewController(store: store, job: job))
    }

    private func setEnabled(_ job: CronJob, enabled: Bool) {
        guard let rest = store.rest else { return }
        Task {
            do {
                if enabled {
                    _ = try await rest.resumeCronJob(id: job.id)
                } else {
                    _ = try await rest.pauseCronJob(id: job.id)
                }
            } catch {
                self.showError(enabled ? "Could not resume “\(job.name)”" : "Could not pause “\(job.name)”",
                               detail: error.localizedDescription)
            }
            await store.refreshCronJobs()
        }
    }

    private func runNow(_ job: CronJob) {
        guard let rest = store.rest else { return }
        Task {
            do {
                _ = try await rest.triggerCronJob(id: job.id)
            } catch {
                self.showError("Could not run “\(job.name)”", detail: error.localizedDescription)
            }
            await store.refreshCronJobs()
        }
    }

    private func confirmDelete(_ job: CronJob) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(job.name.isEmpty ? job.id : job.name)”?"
        alert.informativeText = "The schedule is removed permanently. Past run history stays in your sessions."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.delete(job)
        }
    }

    private func delete(_ job: CronJob) {
        guard let rest = store.rest else { return }
        Task {
            do {
                try await rest.deleteCronJob(id: job.id)
            } catch {
                self.showError("Could not delete “\(job.name)”", detail: error.localizedDescription)
            }
            await store.refreshCronJobs()
        }
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Helper views

/// Root view painting the content-area background (design --bg).
private final class AutomationsBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bg.cgColor
    }
}
