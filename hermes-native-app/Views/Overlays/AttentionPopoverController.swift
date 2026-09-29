//
//  AttentionPopoverController.swift
//  hermes-native-app
//
//  Toolbar-bell popover (design spec §6 "Attention popover"): transient,
//  374 pt wide NSPopover listing every pending blocking interaction across
//  all sessions (`HermesStore.attentionItems`) as always-expanded cards with
//  inline actions. Footer jumps to the Overview (⌘0).
//

import AppKit
import Combine

/// Wraps the NSPopover; MainWindowController anchors it to the bell button
/// and AppDelegate opens it for View ▸ Needs Attention (⌘9).
@MainActor
final class AttentionPopoverController: NSObject {
    private let listController: AttentionPopoverListController
    private var popover: NSPopover?

    init(store: HermesStore, coordinator: SectionCoordinator) {
        listController = AttentionPopoverListController(store: store)
        super.init()
        listController.onOpenOverview = { [weak self, weak coordinator] in
            coordinator?.navigate(to: .dashboard)
            self?.close()
        }
    }

    var isShown: Bool { popover?.isShown ?? false }

    func toggle(relativeTo anchor: NSView) {
        if isShown {
            close()
        } else {
            show(relativeTo: anchor)
        }
    }

    func show(relativeTo anchor: NSView) {
        guard anchor.window != nil else { return }
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = listController
            self.popover = popover
        }
        guard popover?.isShown != true else { return }
        popover?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func close() {
        popover?.performClose(nil)
    }
}

// MARK: - List view controller

private final class AttentionPopoverListController: NSViewController {
    private let store: HermesStore
    private var cancellables = Set<AnyCancellable>()

    var onOpenOverview: (() -> Void)?

    private let countChip = ChipLabel()
    private let cardsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let scrollDocument = FlippedView()
    private let emptyView = NSView()
    private var scrollHeightConstraint: NSLayoutConstraint?

    private static let popoverWidth: CGFloat = 374
    private static let maxListHeight: CGFloat = 470

    init(store: HermesStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: Self.popoverWidth).isActive = true

        // — Header: "Needs attention <count>" + "Across all platforms"
        let title = NSTextField.label("Needs attention", size: 14, weight: .semibold, color: Theme.tx)

        let caption = NSTextField.label("Across all platforms", size: 11.5, color: Theme.tx3)

        let header = NSStackView(views: [title, countChip, NSView(), caption])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 13, left: 15, bottom: 11, right: 15)
        header.translatesAutoresizingMaskIntoConstraints = false

        // — Scrolling card list
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 8
        cardsStack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 5, right: 9)
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollDocument.addSubview(cardsStack)
        cardsStack.pin(to: scrollDocument)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollDocument.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = scrollDocument
        NSLayoutConstraint.activate([
            scrollDocument.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            scrollDocument.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            scrollDocument.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 100)
        heightConstraint.isActive = true
        scrollHeightConstraint = heightConstraint

        // — Empty state: green check + "You're all caught up"
        buildEmptyState()

        // — Footer: "Open in Overview   ⌘0"
        let footer = FooterLinkRow(title: "Open in Overview", shortcut: "⌘0") { [weak self] in
            self?.onOpenOverview?()
        }

        let column = NSStackView(views: [header, scrollView, emptyView, footer])
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
            scrollView.widthAnchor.constraint(equalTo: column.widthAnchor),
            emptyView.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        view = root
    }

    private func buildEmptyState() {
        let check = SymbolChipView(symbolName: "checkmark",
                                   tint: Theme.ok,
                                   background: Theme.ok.withAlphaComponent(0.16),
                                   side: 34, cornerRadius: 17, pointSize: 14)
        let headline = NSTextField.label("You’re all caught up", size: 13.5, weight: .medium, color: Theme.tx)
        let sub = NSTextField(wrappingLabelWithString:
            "No approvals or failures waiting. Hermes surfaces anything urgent here, from any platform.")
        sub.font = NSFont.systemFont(ofSize: 12)
        sub.textColor = Theme.tx3
        sub.alignment = .center
        sub.preferredMaxLayoutWidth = 230

        let stack = NSStackView(views: [check, headline, sub])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 32, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: emptyView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: emptyView.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            sub.widthAnchor.constraint(lessThanOrEqualToConstant: 230),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.$attentionItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.render(items) }
            .store(in: &cancellables)
        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            guard let self else { return }
            self.render(self.store.attentionItems)
        }
        render(store.attentionItems)
    }

    private func render(_ items: [AttentionItem]) {
        countChip.text = "\(items.count)"
        countChip.isHidden = items.isEmpty

        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let card = makeCard(for: item)
            cardsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cardsStack.widthAnchor, constant: -18).isActive = true
        }

        let hasItems = !items.isEmpty
        scrollView.isHidden = !hasItems
        emptyView.isHidden = hasItems

        if hasItems {
            cardsStack.layoutSubtreeIfNeeded()
            let contentHeight = cardsStack.fittingSize.height
            scrollHeightConstraint?.constant = min(contentHeight, Self.maxListHeight)
        } else {
            scrollHeightConstraint?.constant = 0
        }

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.popoverWidth, height: view.fittingSize.height)
    }

    // MARK: Card construction

    private func makeCard(for item: AttentionItem) -> NSView {
        let card = PopoverAttentionCard()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        content.edgeInsets = NSEdgeInsets(top: 11, left: 15, bottom: 11, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        content.pin(to: card)

        func addFullWidth(_ view: NSView) {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -27).isActive = true
        }

        func addHeader(symbol: String, title: String) {
            let chip = SymbolChipView(symbolName: symbol,
                                      tint: Theme.acc,
                                      background: Theme.accSoft,
                                      side: 24, cornerRadius: 7, pointSize: 12)
            let titleField = NSTextField(wrappingLabelWithString: title)
            titleField.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            titleField.textColor = Theme.tx
            let time = NSTextField.label(
                Self.relativeFormatter.localizedString(for: item.receivedAt, relativeTo: Date()),
                size: 10.5, color: Theme.tx3)
            let row = NSStackView(views: [chip, titleField, NSView(), time])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 9
            addFullWidth(row)
        }

        func addSub(_ text: String) {
            guard !text.isEmpty else { return }
            let sub = NSTextField(wrappingLabelWithString: text)
            sub.font = NSFont.systemFont(ofSize: 12)
            sub.textColor = Theme.tx2
            addFullWidth(sub)
        }

        func addCommandBox(_ command: String) {
            guard !command.isEmpty else { return }
            addFullWidth(MonoCommandBox(command: command))
        }

        func addActions(_ buttons: [NSView]) {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 7
            content.addArrangedSubview(row)
        }

        func addInputRow(placeholder: String, secure: Bool, submitTitle: String,
                         submit: @escaping (String) -> Void) {
            let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
            field.placeholderString = placeholder
            field.font = Theme.bodyFont
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let send = AccentActionButton(title: submitTitle) { [weak field] in
                guard let field, !field.stringValue.isEmpty else { return }
                submit(field.stringValue)
            }
            let row = NSStackView(views: [field, send])
            row.orientation = .horizontal
            row.spacing = 7
            addFullWidth(row)
        }

        let dismissButton = BezelActionButton(title: "Dismiss") { [weak self] in
            guard let self else { return }
            self.store.dismissAttention(item)
            ToastPresenter.shared.show(text: "Dismissed")
        }

        switch item.kind {
        case .approval(let payload):
            addHeader(symbol: "checkmark.shield",
                      title: payload.description.isEmpty ? "Approve command" : payload.description)
            addCommandBox(payload.command)
            addSub("Hermes is waiting for permission to run this command.")
            let allowOnce = AccentActionButton(title: "Allow Once") { [weak self] in
                guard let self else { return }
                Task { await self.store.answerApproval(item, choice: .once) }
                ToastPresenter.shared.show(text: "Allowed once")
            }
            let always = BezelActionButton(title: "Always Allow") { [weak self] in
                guard let self else { return }
                Task { await self.store.answerApproval(item, choice: .always) }
                ToastPresenter.shared.show(text: "Added to allowlist")
            }
            always.isEnabled = payload.allowPermanent
            let deny = BezelActionButton(title: "Deny…", titleColor: Theme.danger) { [weak self] in
                self?.confirmDeny(item: item, payload: payload)
            }
            addActions([allowOnce, always, deny])

        case .clarify(let payload):
            addHeader(symbol: "questionmark.bubble", title: "Hermes needs an answer")
            addSub(payload.question)
            if let choices = payload.choices, !choices.isEmpty {
                let buttons: [NSView] = choices.prefix(4).map { choice in
                    BezelActionButton(title: choice) { [weak self] in
                        guard let self else { return }
                        Task { await self.store.answerClarify(item, answer: choice) }
                    }
                }
                addActions(buttons)
            } else {
                addInputRow(placeholder: "Type an answer…", secure: false, submitTitle: "Reply") { [weak self] answer in
                    guard let self else { return }
                    Task { await self.store.answerClarify(item, answer: answer) }
                }
            }
            addActions([dismissButton])

        case .sudo:
            addHeader(symbol: "lock.shield", title: "Administrator password requested")
            addSub("Hermes needs your sudo password to continue. It is sent straight to the local backend (2-minute window).")
            addInputRow(placeholder: "Password", secure: true, submitTitle: "Send") { [weak self] password in
                guard let self else { return }
                Task { await self.store.answerSudo(item, password: password) }
            }
            addActions([dismissButton])

        case .secret(let payload):
            addHeader(symbol: "key",
                      title: payload.prompt.isEmpty ? "Secret value requested" : payload.prompt)
            addSub(payload.envVar.isEmpty ? "" : "Stored as \(payload.envVar).")
            addInputRow(placeholder: "Value", secure: true, submitTitle: "Send") { [weak self] value in
                guard let self else { return }
                Task { await self.store.answerSecret(item, value: value) }
            }
            addActions([dismissButton])

        case .terminalRead:
            addHeader(symbol: "terminal", title: "Terminal is asking for input")
            addSub("Your reply is typed into the running terminal session (30-second window).")
            addInputRow(placeholder: "Text to send…", secure: false, submitTitle: "Send") { [weak self] text in
                guard let self else { return }
                Task { await self.store.answerTerminalRead(item, text: text) }
            }
            addActions([dismissButton])
        }

        return card
    }

    /// Deny → stock NSAlert confirmation (spec §6 "Deny confirmation"), then
    /// approval.respond {choice: deny}. No toast for deny, per the design.
    private func confirmDeny(item: AttentionItem, payload: ApprovalRequestPayload) {
        let alert = NSAlert()
        alert.messageText = "Deny this command?"
        var informative = payload.description
        if !informative.isEmpty { informative += "\n\n" }
        informative += "Hermes won’t run it. It stays in the conversation, so you can allow it later."
        alert.informativeText = informative
        if !payload.command.isEmpty {
            // NSAlert sizes accessory views by frame, so resolve the fitting
            // height for the fixed width up front.
            let box = MonoCommandBox(command: payload.command, showsPrompt: false)
            box.translatesAutoresizingMaskIntoConstraints = false
            let width = box.widthAnchor.constraint(equalToConstant: 220)
            width.isActive = true
            box.layoutSubtreeIfNeeded()
            let height = box.fittingSize.height
            width.isActive = false
            box.translatesAutoresizingMaskIntoConstraints = true
            box.frame = NSRect(x: 0, y: 0, width: 220, height: max(height, 28))
            alert.accessoryView = box
        }
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await store.answerApproval(item, choice: .deny) }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Pieces

/// Neutral raised card with hairline border and a 3 px accent bar on the left
/// (all attention items are requests → accent; red is reserved for flags,
/// which have no backend source yet).
private final class PopoverAttentionCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.bgRaised.setFill()
        path.fill()
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        Theme.acc.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Rounded square with a centered tinted SF symbol (icon chips, green check).
private final class SymbolChipView: NSView {
    private let background: NSColor
    private let side: CGFloat

    init(symbolName: String, tint: NSColor, background: NSColor,
         side: CGFloat, cornerRadius: CGFloat, pointSize: CGFloat) {
        self.background = background
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = .init(pointSize: pointSize, weight: .semibold)
        imageView.contentTintColor = tint
        addSubview(imageView)
        imageView.center(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = background.cgColor
    }
}

/// Small accent count chip ("Needs attention <n>").
private final class ChipLabel: NSView {
    var text: String = "" {
        didSet { label.stringValue = text }
    }

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.acc
        addSubview(label)
        label.pin(to: self, insets: NSEdgeInsets(top: 1, left: 8, bottom: 1, right: 8))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        label.textColor = Theme.acc
        layer?.backgroundColor = Theme.accSoft.cgColor
    }
}

/// Inset mono box: "$ command" with an accent prompt.
private final class MonoCommandBox: NSView {
    init(command: String, showsPrompt: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1

        let text = NSMutableAttributedString()
        if showsPrompt {
            text.append(NSAttributedString(string: "$ ", attributes: [
                .font: Theme.monoFont(ofSize: 11.5),
                .foregroundColor: Theme.acc,
            ]))
        }
        text.append(NSAttributedString(string: command, attributes: [
            .font: Theme.monoFont(ofSize: 11.5),
            .foregroundColor: Theme.tx,
        ]))
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
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

/// Accent-filled push button (design's default-action button).
private final class AccentActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        bezelColor = Theme.acc
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// Standard bezel button with a closure action (optionally tinted title,
/// e.g. red "Deny…").
private final class BezelActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, titleColor: NSColor? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        if let titleColor {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: titleColor,
            ])
        } else {
            self.title = title
            font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// Footer link row: hairline on top, accent link text + trailing shortcut.
private final class FooterLinkRow: NSControl {
    private let handler: () -> Void

    init(title: String, shortcut: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        let link = NSTextField.label(title, size: 12.5, weight: .medium, color: Theme.acc)

        let kbd = NSTextField.label(shortcut, size: 12, color: Theme.tx3)

        let row = NSStackView(views: [link, NSView(), kbd])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { handler() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
