//
//  AttentionCardView.swift
//  hermes-native-app
//
//  One "Needs attention" card: neutral raised card with a 3px colored left
//  bar, icon chip, title, time-ago and chevron; clicking the header expands
//  a detail area with the mono command box, description and action buttons.
//  Approvals answer via approval.respond (once/always/deny — deny behind an
//  NSAlert confirmation); clarifies answer via clarify.respond; everything
//  else offers Dismiss (the server times the request out on its own).
//

import AppKit

final class AttentionCardView: NSView {
    let itemID: UUID
    var onToggle: ((AttentionCardView) -> Void)?

    private let item: AttentionItem
    private let store: HermesStore
    private let barView = DashboardBarView()
    private let chevron = NSImageView()
    private let detailContainer = NSStackView()
    private var isExpanded: Bool

    init(item: AttentionItem, sessionName: String?, expanded: Bool, store: HermesStore) {
        self.item = item
        self.store = store
        self.itemID = item.id
        self.isExpanded = expanded
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        buildUI(sessionName: sessionName)
        applyExpansion(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.line.cgColor
    }

    // MARK: Kind attributes

    /// Red for destructive/full-access kinds; accent for the rest.
    private var isDangerKind: Bool {
        if case .sudo = item.kind { return true }
        return false
    }

    private var barColor: NSColor { isDangerKind ? Theme.danger : Theme.acc }
    private var chipBackground: NSColor { isDangerKind ? DashboardColors.dangerSoft : Theme.accSoft }

    private var symbolName: String {
        switch item.kind {
        case .approval: return "checkmark.shield"
        case .clarify: return "questionmark.bubble"
        case .sudo: return "lock.shield"
        case .secret: return "key"
        case .terminalRead: return "terminal"
        }
    }

    static func title(for item: AttentionItem, sessionName: String?) -> String {
        let name = (sessionName?.isEmpty == false) ? sessionName! : "Hermes"
        switch item.kind {
        case .approval: return "\(name) wants to run a shell command"
        case .clarify: return "\(name) needs an answer"
        case .sudo: return "\(name) requests administrator access"
        case .secret(let payload):
            return payload.envVar.isEmpty
                ? "\(name) needs a secret"
                : "\(name) needs a secret (\(payload.envVar))"
        case .terminalRead: return "\(name) wants to read your terminal"
        }
    }

    private var descriptionText: String {
        switch item.kind {
        case .approval(let payload):
            return payload.description.isEmpty
                ? "This command needs your OK before it runs."
                : payload.description
        case .clarify(let payload):
            return payload.question
        case .sudo:
            return "Hermes asked for your administrator password. The dashboard doesn't collect passwords — dismissing lets the request time out on the server."
        case .secret(let payload):
            return payload.prompt.isEmpty
                ? "Hermes asked for a secret value. Dismissing lets the request time out on the server."
                : payload.prompt
        case .terminalRead:
            return "Hermes wants to read output from your terminal session. Dismissing lets the request time out on the server."
        }
    }

    private var commandText: String? {
        if case .approval(let payload) = item.kind, !payload.command.isEmpty {
            return payload.command
        }
        return nil
    }

    // MARK: UI

    private func buildUI(sessionName: String?) {
        // 3px left accent/danger bar, flush with the rounded edge.
        barView.color = barColor
        barView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barView)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: leadingAnchor),
            barView.topAnchor.constraint(equalTo: topAnchor),
            barView.bottomAnchor.constraint(equalTo: bottomAnchor),
            barView.widthAnchor.constraint(equalToConstant: 3),
        ])
        column.pin(to: self, insets: NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 0))

        // — header row (whole row toggles expansion)
        let header = DashboardClickRow { [weak self] in
            guard let self else { return }
            self.onToggle?(self)
        }

        let chip = IconChipView(symbolName: symbolName, tint: barColor, background: chipBackground)

        let titleField = NSTextField(labelWithString: Self.title(for: item, sessionName: sessionName))
        titleField.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        titleField.textColor = Theme.tx
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeField = NSTextField.label(DashboardFormat.timeAgo(item.receivedAt), size: 11.5, color: Theme.tx3)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand")
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Theme.tx3

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let headerStack = NSStackView(views: [chip, titleField, spacer, timeField, chevron])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.edgeInsets = NSEdgeInsets(top: 12, left: 15, bottom: 12, right: 15)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)
        headerStack.pin(to: header)

        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // — detail (collapsible)
        detailContainer.orientation = .vertical
        detailContainer.alignment = .leading
        detailContainer.spacing = 10
        detailContainer.edgeInsets = NSEdgeInsets(top: 0, left: 55, bottom: 15, right: 16)
        column.addArrangedSubview(detailContainer)
        detailContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        if let command = commandText {
            let box = MonoCommandBox(command: command, promptColor: barColor)
            detailContainer.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: detailContainer.widthAnchor, constant: -71).isActive = true
        }

        let descriptionField = NSTextField.label(descriptionText, size: 12.5, color: Theme.tx2, wrapping: true)
        detailContainer.addArrangedSubview(descriptionField)
        descriptionField.widthAnchor.constraint(equalTo: detailContainer.widthAnchor, constant: -71).isActive = true

        buildActions()
    }

    private func buildActions() {
        switch item.kind {
        case .approval(let payload):
            let allowOnce = DashboardHandlerButton(title: "Allow Once") { [weak self] in
                self?.respondApproval(.once)
            }
            allowOnce.keyEquivalent = "\r" // accent-filled default button

            var buttons: [NSButton] = [allowOnce]
            if payload.allowPermanent {
                buttons.append(DashboardHandlerButton(title: "Always Allow") { [weak self] in
                    self?.respondApproval(.always)
                })
            }
            let deny = DashboardHandlerButton(title: "Deny…") { [weak self] in
                self?.confirmDeny(payload: payload)
            }
            deny.attributedTitle = NSAttributedString(
                string: "Deny…",
                attributes: [
                    .foregroundColor: Theme.danger,
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular)),
                ]
            )
            buttons.append(deny)
            addButtonRow(buttons)

        case .clarify(let payload):
            if let choices = payload.choices, !choices.isEmpty {
                let choiceButtons = choices.map { choice in
                    DashboardHandlerButton(title: choice) { [weak self] in
                        self?.respondClarify(answer: choice)
                    }
                }
                addButtonRow(choiceButtons)
            }
            let field = NSTextField(string: "")
            field.placeholderString = "Type an answer…"
            field.font = Theme.bodyFont
            field.bezelStyle = .roundedBezel
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            let send = DashboardHandlerButton(title: "Send") { [weak self, weak field] in
                guard let answer = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                      !answer.isEmpty else { return }
                self?.respondClarify(answer: answer)
            }
            send.keyEquivalent = "\r"
            let row = NSStackView(views: [field, send])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            detailContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailContainer.widthAnchor, constant: -71).isActive = true
            field.setContentHuggingPriority(.init(1), for: .horizontal)

        case .sudo, .secret, .terminalRead:
            addButtonRow([DashboardHandlerButton(title: "Dismiss") { [weak self] in
                guard let self else { return }
                self.store.dismissAttention(self.item)
            }])
        }
    }

    private func addButtonRow(_ buttons: [NSButton]) {
        if let last = detailContainer.arrangedSubviews.last {
            detailContainer.setCustomSpacing(12, after: last)
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        detailContainer.addArrangedSubview(row)
    }

    // MARK: Actions

    private func respondApproval(_ choice: ApprovalChoice) {
        let store = store
        let item = item
        Task { await store.answerApproval(item, choice: choice) }
    }

    private func respondClarify(answer: String) {
        let store = store
        let item = item
        Task { await store.answerClarify(item, answer: answer) }
    }

    /// Deny confirmation: bold question, mono command, Deny/Cancel.
    private func confirmDeny(payload: ApprovalRequestPayload) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Deny this command?"
        alert.informativeText = "Hermes won't run it. It stays in the conversation, so you can allow it later."

        if !payload.command.isEmpty {
            let width: CGFloat = 340
            let commandField = NSTextField(wrappingLabelWithString: payload.command)
            commandField.font = Theme.monoFont(ofSize: 11)
            commandField.textColor = Theme.tx2
            commandField.isSelectable = true
            let height = commandField.cell?.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            ).height ?? 16
            commandField.frame = NSRect(x: 0, y: 0, width: width, height: ceil(height))
            alert.accessoryView = commandField
        }

        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.respondApproval(.deny)
        }
    }

    // MARK: Expansion

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        applyExpansion(animated: true)
    }

    private func applyExpansion(animated: Bool) {
        let apply = {
            // Toggle inside the group so the stack view animates the height
            // change together with the chevron, instead of the detail popping.
            self.detailContainer.isHidden = !self.isExpanded
            self.chevron.frameCenterRotation = self.isExpanded ? 0 : 90
        }
        if animated {
            Motion.animate(0.18, apply)
        } else {
            apply()
        }
    }
}

// MARK: - Pieces

/// 28×28 rounded icon chip with a soft semantic wash.
private final class IconChipView: NSView {
    private let background: NSColor

    init(symbolName: String, tint: NSColor, background: NSColor) {
        self.background = background
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        constrainSize(NSSize(width: 28, height: 28))
        icon.center(in: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = background.cgColor }
}

/// Inset mono "$ command" box.
private final class MonoCommandBox: NSView {
    init(command: String, promptColor: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1

        let text = NSMutableAttributedString(
            string: "$ ",
            attributes: [.font: Theme.monoFont(ofSize: 12), .foregroundColor: promptColor]
        )
        text.append(NSAttributedString(
            string: command,
            attributes: [.font: Theme.monoFont(ofSize: 12), .foregroundColor: Theme.tx]
        ))

        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = text
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        field.pin(to: self, insets: NSEdgeInsets(top: 8, left: 11, bottom: 8, right: 11))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.bgInset.cgColor
        layer?.borderColor = Theme.line.cgColor
    }
}

/// Whole-row click target (card header).
final class DashboardClickRow: NSControl {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// NSButton driven by a closure (rounded bezel).
final class DashboardHandlerButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .regular
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
