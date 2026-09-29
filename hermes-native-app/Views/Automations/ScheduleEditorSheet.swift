import AppKit

/// Window-sheet for creating or editing a cron schedule.
/// Fields: Name · Prompt (NSTextView) · Schedule (cron string + presets) ·
/// Deliver-to (optional). Saves via POST/PUT /api/cron/jobs then refreshes.
final class ScheduleEditorViewController: NSViewController {

    private let store: HermesStore
    private let job: CronJob?

    private let nameField = NSTextField()
    private let promptScroll = NSTextView.scrollableTextView()
    private var promptView: NSTextView { promptScroll.documentView as! NSTextView }
    private let scheduleField = NSTextField()
    private let deliverField = NSTextField()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let busySpinner = NSProgressIndicator()

    private static let presets: [(title: String, cron: String)] = [
        ("Hourly", "0 * * * *"),
        ("Daily 9am", "0 9 * * *"),
        ("Weekdays 7:30", "30 7 * * 1-5"),
        ("Weekly Mon 9", "0 9 * * 1"),
    ]

    /// Pass nil to create a new schedule.
    init(store: HermesStore, job: CronJob?) {
        self.store = store
        self.job = job
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField.label(job == nil ? "New schedule" : "Edit schedule",
                                      size: 15, weight: .semibold, color: Theme.tx)

        nameField.placeholderString = "Weekly metrics report"
        nameField.font = Theme.bodyFont

        promptView.font = Theme.bodyFont
        promptView.isRichText = false
        promptView.allowsUndo = true
        promptView.textContainerInset = NSSize(width: 4, height: 6)
        promptScroll.borderType = .bezelBorder
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true

        scheduleField.placeholderString = "0 9 * * 1   ·   every 30m   ·   2026-07-04T09:00"
        scheduleField.font = Theme.monoFont(ofSize: 12)

        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        for (index, preset) in Self.presets.enumerated() {
            let button = NSButton(title: preset.title, target: self, action: #selector(presetClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            button.tag = index
            presetRow.addArrangedSubview(button)
        }
        presetRow.addArrangedSubview(NSView())

        let scheduleHint = NSTextField.label("Cron expression, “every 30m” interval, or a one-shot timestamp.",
                                             size: 11, color: Theme.tx3)

        deliverField.placeholderString = "local · telegram · slack …"
        deliverField.font = Theme.bodyFont

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.title = job == nil ? "Create Schedule" : "Save Changes"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.isDisplayedWhenStopped = false

        let buttons = NSStackView(views: [busySpinner, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let column = NSStackView(views: [
            title,
            fieldLabel("NAME"), nameField,
            fieldLabel("PROMPT"), promptScroll,
            fieldLabel("SCHEDULE"), scheduleField, presetRow, scheduleHint,
            fieldLabel("DELIVER TO (OPTIONAL)"), deliverField,
            buttons,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(16, after: title)
        column.setCustomSpacing(14, after: nameField)
        column.setCustomSpacing(14, after: scheduleHint)
        column.setCustomSpacing(18, after: deliverField)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 480),
            column.topAnchor.constraint(equalTo: view.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for control in [nameField, scheduleField, deliverField] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }
        promptScroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        buttons.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true

        self.view = view
        populate()
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.sectionLabelFont
        label.textColor = Theme.tx3
        return label
    }

    private func populate() {
        guard let job else { return }
        nameField.stringValue = job.name
        promptView.string = job.prompt ?? ""
        scheduleField.stringValue = job.scheduleExpression ?? job.scheduleDisplay ?? ""
        if let deliver = job.deliver, deliver.lowercased() != "local" {
            deliverField.stringValue = deliver
        }
    }

    // MARK: Actions

    @objc private func presetClicked(_ sender: NSButton) {
        guard Self.presets.indices.contains(sender.tag) else { return }
        scheduleField.stringValue = Self.presets[sender.tag].cron
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(self)
    }

    @objc private func save(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let prompt = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = scheduleField.stringValue.trimmingCharacters(in: .whitespaces)
        let deliver = deliverField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !schedule.isEmpty else {
            showValidation("Enter a schedule — a cron expression, “every 30m”, or a timestamp.")
            return
        }
        guard !prompt.isEmpty else {
            showValidation("Enter a prompt — this is what Hermes runs on each tick.")
            return
        }
        guard let rest = store.rest else {
            showValidation("The Hermes backend is not connected yet.")
            return
        }

        setBusy(true)
        let editing = job
        Task {
            do {
                let body: JSONValue = .object([
                    "name": .string(name),
                    "prompt": .string(prompt),
                    "schedule": .string(schedule),
                    "deliver": .string(deliver.isEmpty ? "local" : deliver),
                ])
                if let editing {
                    _ = try await rest.updateCronJob(id: editing.id, updates: body)
                } else {
                    _ = try await rest.createCronJob(body)
                }
                await store.refreshCronJobs()
                setBusy(false)
                dismiss(self)
            } catch {
                setBusy(false)
                showValidation("Could not save the schedule: \(error.localizedDescription)")
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        saveButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        if busy { busySpinner.startAnimation(nil) } else { busySpinner.stopAnimation(nil) }
    }

    private func showValidation(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = job == nil ? "Can't create schedule" : "Can't save schedule"
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
