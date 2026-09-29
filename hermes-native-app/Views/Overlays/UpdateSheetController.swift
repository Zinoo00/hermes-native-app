//
//  UpdateSheetController.swift
//  hermes-native-app
//
//  Software Update sheet (design spec §6): window-modal sheet that drops from
//  the top (`beginSheet`). Stages: checking → available / up-to-date →
//  updating (streaming step line from the backgrounded action) → done.
//  Backend: GET /api/hermes/update/check, POST /api/hermes/update,
//  GET /api/actions/update/status, POST /api/gateway/restart.
//

import AppKit

@MainActor
final class UpdateSheetController: NSObject {

    private enum Stage {
        case checking
        case available(UpdateCheck)
        case upToDate(UpdateCheck)
        case updating(step: String)
        case done(message: String)
        case failed(message: String)
    }

    private var stage: Stage = .checking {
        didSet { render() }
    }

    private weak var hostWindow: NSWindow?
    private var sheetWindow: NSWindow?
    private var workTask: Task<Void, Never>?

    // Stable views
    private let subtitleField = NSTextField(labelWithString: "")
    private let stageBox = NSStackView()

    private static let sheetWidth: CGFloat = 424

    // MARK: Presentation

    func present(on window: NSWindow) {
        guard sheetWindow == nil else { return }
        hostWindow = window

        let controller = NSViewController()
        controller.view = buildRootView()
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        sheetWindow = sheet

        stage = .checking
        window.beginSheet(sheet)
        startCheck()
    }

    private func dismiss() {
        workTask?.cancel()
        workTask = nil
        if let sheetWindow {
            hostWindow?.endSheet(sheetWindow)
        }
        sheetWindow = nil
    }

    // MARK: UI skeleton

    private func buildRootView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: Self.sheetWidth).isActive = true

        // Header: accent icon tile + "Hermes Desktop backend" + stage subtitle.
        let icon = CaduceusIconTile()
        let title = NSTextField.label("Hermes Desktop backend", size: 16, weight: .semibold, color: Theme.tx)
        subtitleField.font = NSFont.systemFont(ofSize: 12.5)
        subtitleField.textColor = Theme.tx2

        let titleColumn = NSStackView(views: [title, subtitleField])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2

        let header = NSStackView(views: [icon, titleColumn])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 15
        header.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 0, right: 22)
        header.translatesAutoresizingMaskIntoConstraints = false

        stageBox.orientation = .vertical
        stageBox.alignment = .leading
        stageBox.spacing = 12
        stageBox.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 20, right: 22)
        stageBox.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [header, stageBox])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            stageBox.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        return root
    }

    // MARK: Stage rendering

    private func render() {
        guard sheetWindow != nil else { return }
        stageBox.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch stage {
        case .checking:
            subtitleField.stringValue = currentVersionSubtitle()
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            let label = secondaryLabel("Checking for updates…")
            addRow([spinner, label])

        case .available(let check):
            subtitleField.stringValue = "A new version is available"
            let version = NSTextField.label("Version \(check.currentVersion)", size: 13, weight: .semibold, color: Theme.tx)
            let detailText: String
            if let behind = check.behind, behind > 0 {
                detailText = "· \(behind) release\(behind == 1 ? "" : "s") behind"
            } else {
                detailText = "· update available"
            }
            let detail = NSTextField.label(detailText, size: 11.5, color: Theme.tx3)
            addRow([version, detail], spacing: 8)

            // WHAT'S NEW card — only when the backend actually sent a message.
            if let message = check.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addFullWidth(WhatsNewBox(message: message))
            }
            if !check.canApply, !check.updateCommand.isEmpty {
                addFullWidth(secondaryWrappingLabel("This install can’t self-update. Run in a terminal:"))
                addFullWidth(UpdateMonoBox(text: check.updateCommand))
            }

            let later = SheetButton(title: "Later") { [weak self] in self?.dismiss() }
            let update = SheetButton(title: "Update & Restart", isDefault: true) { [weak self] in
                self?.runUpdate(check)
            }
            update.isEnabled = check.canApply
            addButtonRow([later, update])

        case .upToDate(let check):
            subtitleField.stringValue = "You’re now up to date"
            let version = check.currentVersion.isEmpty
                ? (AppEnvironment.shared.store.backendStatus?.version ?? "")
                : check.currentVersion
            let text = version.isEmpty ? "You’re up to date" : "You’re up to date · v\(version)"
            addRow([GreenCheckBadge(), primaryLabel(text)])
            addButtonRow([SheetButton(title: "OK", isDefault: true) { [weak self] in self?.dismiss() }])

        case .updating(let step):
            subtitleField.stringValue = "Updating…"
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            bar.translatesAutoresizingMaskIntoConstraints = false
            addFullWidth(bar)
            let stepLabel = secondaryWrappingLabel(step)
            stepLabel.font = Theme.monoFont(ofSize: 11)
            stepLabel.maximumNumberOfLines = 2
            addFullWidth(stepLabel)

        case .done(let message):
            subtitleField.stringValue = "You’re now up to date"
            addRow([GreenCheckBadge(), primaryLabel(message)])
            addButtonRow([SheetButton(title: "Done", isDefault: true) { [weak self] in self?.dismiss() }])

        case .failed(let message):
            subtitleField.stringValue = currentVersionSubtitle()
            let error = secondaryWrappingLabel(message)
            error.textColor = Theme.danger
            addFullWidth(error)
            addButtonRow([SheetButton(title: "Close", isDefault: true) { [weak self] in self?.dismiss() }])
        }

        // Autolayout drives the sheet size; re-fit after swapping stage views.
        if let sheetWindow, let content = sheetWindow.contentView {
            content.layoutSubtreeIfNeeded()
            sheetWindow.setContentSize(content.fittingSize)
        }
    }

    // MARK: Backend flow

    private func startCheck() {
        workTask = Task { [weak self] in
            guard let self else { return }
            guard let rest = AppEnvironment.shared.store.rest else {
                self.stage = .failed(message: "The Hermes backend isn’t connected yet.")
                return
            }
            do {
                let check = try await rest.checkUpdate(force: true)
                guard !Task.isCancelled else { return }
                self.stage = check.updateAvailable ? .available(check) : .upToDate(check)
            } catch {
                guard !Task.isCancelled else { return }
                self.stage = .failed(message: "Update check failed: \(error.localizedDescription)")
            }
        }
    }

    private func runUpdate(_ check: UpdateCheck) {
        stage = .updating(step: "Starting update…")
        workTask = Task { [weak self] in
            guard let self else { return }
            guard let rest = AppEnvironment.shared.store.rest else {
                self.stage = .failed(message: "The Hermes backend isn’t connected.")
                return
            }
            do {
                _ = try await rest.runUpdate()
            } catch {
                self.stage = .failed(message: "Could not start the update: \(error.localizedDescription)")
                return
            }

            // Stream progress from the backgrounded action status endpoint.
            var sawRunning = false
            var polls = 0
            var lastLine = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                polls += 1
                guard let status = try? await rest.actionStatus(name: "update") else {
                    if polls > 8, !sawRunning { break }
                    continue
                }
                if let line = Self.lastOutputLine(of: status) {
                    lastLine = line
                    self.stage = .updating(step: line)
                }
                let running = Self.isRunning(status)
                if running == true { sawRunning = true }
                if running == false, sawRunning || polls > 5 { break }
                if polls > 600 { break } // 10-minute cap
            }
            guard !Task.isCancelled else { return }

            // Verify the result with a fresh check.
            let after = try? await rest.checkUpdate(force: true)
            guard !Task.isCancelled else { return }
            if let after, !after.updateAvailable {
                var message = after.currentVersion.isEmpty
                    ? "Updated" : "Updated to v\(after.currentVersion)"
                // Restart the gateway so the new version is live.
                if (try? await rest.restartGateway()) != nil {
                    message += " · gateway restarted"
                }
                guard !Task.isCancelled else { return }
                self.stage = .done(message: message)
            } else {
                var message = "The update did not complete."
                if !lastLine.isEmpty { message += " Last output: \(lastLine)" }
                if !check.updateCommand.isEmpty { message += "\nTry `\(check.updateCommand)` in a terminal." }
                self.stage = .failed(message: message)
            }
        }
    }

    /// Defensive parse of GET /api/actions/update/status (shape not in the
    /// verified protocol doc).
    private static func isRunning(_ status: JSONValue) -> Bool? {
        if let running = status["running"].bool { return running }
        if let state = status["status"].string ?? status["state"].string {
            return state == "running" || state == "started" || state == "in_progress"
        }
        return nil
    }

    private static func lastOutputLine(of status: JSONValue) -> String? {
        let lines = status["lines"].stringArray
            ?? status["output"].string?.components(separatedBy: "\n")
            ?? status["log"].string?.components(separatedBy: "\n")
        return lines?.reversed().first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: Small helpers

    private func currentVersionSubtitle() -> String {
        if let version = AppEnvironment.shared.store.backendStatus?.version, !version.isEmpty {
            return "Current version \(version)"
        }
        return "Local hermes backend"
    }

    private func addRow(_ views: [NSView], spacing: CGFloat = 10) {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        stageBox.addArrangedSubview(row)
    }

    private func addFullWidth(_ view: NSView) {
        stageBox.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stageBox.widthAnchor, constant: -44).isActive = true
    }

    private func addButtonRow(_ buttons: [NSView]) {
        let row = NSStackView(views: [NSView()] + buttons)
        row.orientation = .horizontal
        row.spacing = 9
        stageBox.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stageBox.widthAnchor, constant: -44).isActive = true
    }

    private func primaryLabel(_ text: String) -> NSTextField {
        NSTextField.label(text, size: 13, color: Theme.tx)
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        NSTextField.label(text, size: 13, color: Theme.tx2)
    }

    private func secondaryWrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12.5)
        label.textColor = Theme.tx2
        return label
    }
}

// MARK: - Pieces

/// 52 pt accent tile with the caduceus glyph (design's update-sheet app icon).
private final class CaduceusIconTile: NSView {
    private let glyph = NSTextField(labelWithString: "☤")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        glyph.font = NSFont.systemFont(ofSize: 30)
        glyph.textColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 52) }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.acc.cgColor
    }
}

/// 22 pt green circle with a white check (done / up-to-date states).
private final class GreenCheckBadge: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        check.contentTintColor = .white
        addSubview(check)
        check.center(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ok.cgColor
    }
}

/// Inset "WHAT'S NEW" release-notes card fed by UpdateCheck.message.
private final class WhatsNewBox: NSView {
    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        let eyebrow = NSTextField.label("WHAT'S NEW", size: 10, weight: .bold, color: Theme.tx3)

        let body = NSTextField(wrappingLabelWithString: message)
        body.font = NSFont.systemFont(ofSize: 12.5)
        body.textColor = Theme.tx

        let stack = NSStackView(views: [eyebrow, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 15, bottom: 12, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgInset.cgColor
        layer?.borderColor = Theme.line.cgColor
    }
}

/// Inset mono box (manual update command when the app can't self-apply).
private final class UpdateMonoBox: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.monoFont(ofSize: 11.5)
        label.textColor = Theme.tx
        label.isSelectable = true
        addSubview(label)
        label.pin(to: self, insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgInset.cgColor
        layer?.borderColor = Theme.line.cgColor
    }
}

/// Standard sheet push button; `isDefault` gets the return-key accent fill.
private final class SheetButton: NSButton {
    private let handler: () -> Void

    init(title: String, isDefault: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .regular
        if isDefault {
            keyEquivalent = "\r"
        }
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
