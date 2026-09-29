import AppKit

/// Actions the composer raises to its owner (the chat content VC).
@MainActor
protocol ChatComposerViewDelegate: AnyObject {
    func composerSubmitRequested()
    func composerStopRequested()
    func composerTextDidChange()
    func composerCycleModeRequested()
    func composerAttachFilesRequested()
    func composerAttachImageRequested()
    func composerAddLinkRequested()
    func composerInsertSkillRequested(_ name: String)
    func composerSpawnSubagentRequested()
    func composerScheduleRequested()
    func composerAddContextRequested(relativeTo view: NSView)
    func composerPermissionModeChanged(_ mode: ChatPermissionMode)

    /// Data for the '+' menu fly-outs.
    var composerSkillNames: [String] { get }
    var composerToolsets: [(name: String, toolCount: Int)] { get }
}

/// Bottom raised card: auto-growing text view, '+' & '@' bezel buttons,
/// permission-mode control, model picker and accent send/stop button.
final class ChatComposerView: NSView, NSTextViewDelegate {

    weak var delegate: ChatComposerViewDelegate?

    let textView = ChatComposerTextView.make()
    let modelButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let permissionControl = ChatPermissionModeControl()

    private let card = ChatCardView(fill: { Theme.bgRaised }, stroke: { Theme.line2 }, radius: 15)
    private let textScroll = NSScrollView()
    private let plusButton = ChatBezelButton(symbolName: "plus")
    private let atButton = ChatBezelButton(text: "@")
    private let sendButton = ChatSendButton()
    private var textHeightConstraint: NSLayoutConstraint!
    private var isRunning = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        card.wantsLayer = true
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.10
        card.layer?.shadowRadius = 9
        card.layer?.shadowOffset = NSSize(width: 0, height: -2)
        addSubview(card)

        // Editor.
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in self?.submitTapped() }
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textHeightConstraint = textScroll.heightAnchor.constraint(equalToConstant: 30)

        // Controls row.
        plusButton.target = self
        plusButton.action = #selector(plusTapped)
        plusButton.toolTip = "Attach files, skills, tools…"
        atButton.target = self
        atButton.action = #selector(atTapped)
        atButton.toolTip = "Add context — files, folders, git diffs, URLs"

        permissionControl.onModeChange = { [weak self] mode in
            self?.delegate?.composerPermissionModeChanged(mode)
        }

        modelButton.translatesAutoresizingMaskIntoConstraints = false
        modelButton.controlSize = .small
        modelButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        (modelButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom

        sendButton.target = self
        sendButton.action = #selector(sendTapped)

        let leftGroup = NSStackView(views: [plusButton, atButton, permissionControl])
        leftGroup.orientation = .horizontal
        leftGroup.spacing = 7

        let rightGroup = NSStackView(views: [modelButton, sendButton])
        rightGroup.orientation = .horizontal
        rightGroup.spacing = 7

        let controls = NSStackView(views: [leftGroup, NSView(), rightGroup])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(textScroll)
        card.addSubview(controls)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            textScroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            textScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            textScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            textHeightConstraint,

            controls.topAnchor.constraint(equalTo: textScroll.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            controls.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        updateSendEnabled()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textDidChangeInternally()
        }
    }

    func clear() {
        text = ""
    }

    /// Appends a token (e.g. "@file:/path") to the editor with spacing.
    func appendToken(_ token: String) {
        var current = textView.string
        if !current.isEmpty, !current.hasSuffix(" "), !current.hasSuffix("\n") {
            current += " "
        }
        textView.string = current + token + " "
        textDidChangeInternally()
        window?.makeFirstResponder(textView)
    }

    func setRunning(_ running: Bool) {
        isRunning = running
        sendButton.showsStop = running
        updateSendEnabled()
    }

    func setModelTitle(_ model: String, effort: String?) {
        let title = effort.map { "\(model) · \($0)" } ?? model
        if let item = modelButton.itemArray.first {
            item.title = title
        } else {
            modelButton.addItem(withTitle: title)
        }
        modelButton.synchronizeTitleAndSelectedItem()
    }

    func refreshAccent() {
        sendButton.needsDisplay = true
        permissionControl.needsDisplay = true
        for subview in permissionControl.subviews { subview.needsDisplay = true }
    }

    // MARK: - Actions

    @objc private func sendTapped() {
        if isRunning {
            delegate?.composerStopRequested()
        } else {
            submitTapped()
        }
    }

    private func submitTapped() {
        delegate?.composerSubmitRequested()
    }

    @objc private func atTapped() {
        delegate?.composerAddContextRequested(relativeTo: atButton)
    }

    @objc private func plusTapped() {
        let menu = NSMenu()

        menu.addItem(makeItem("Attach files…", symbol: "paperclip", action: #selector(menuAttachFiles)))
        menu.addItem(makeItem("Add image", symbol: "photo", action: #selector(menuAttachImage)))
        menu.addItem(makeItem("Add a link", symbol: "link", action: #selector(menuAddLink)))
        menu.addItem(.separator())

        // Skills fly-out (real skills from the backend).
        let skillsItem = makeItem("Skills", symbol: "sparkle", action: nil)
        let skillsMenu = NSMenu()
        let skillNames = delegate?.composerSkillNames ?? []
        if skillNames.isEmpty {
            let empty = NSMenuItem(title: "No skills yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            skillsMenu.addItem(empty)
        } else {
            for name in skillNames {
                let item = NSMenuItem(title: name, action: #selector(menuInsertSkill(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.attributedTitle = NSAttributedString(string: name, attributes: [
                    .font: Theme.monoFont(ofSize: 12),
                ])
                skillsMenu.addItem(item)
            }
        }
        skillsItem.submenu = skillsMenu
        menu.addItem(skillsItem)

        // Tools & MCP fly-out (informational; from session.info tool map).
        let toolsItem = makeItem("Tools & MCP", symbol: "wrench", action: nil)
        let toolsMenu = NSMenu()
        let toolsets = delegate?.composerToolsets ?? []
        if toolsets.isEmpty {
            let empty = NSMenuItem(title: "No toolsets reported", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            toolsMenu.addItem(empty)
        } else {
            for toolset in toolsets {
                let title = toolset.toolCount > 0
                    ? "\(toolset.name) — \(toolset.toolCount) tools"
                    : toolset.name
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                toolsMenu.addItem(item)
            }
        }
        toolsItem.submenu = toolsMenu
        menu.addItem(toolsItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Spawn a subagent", symbol: "point.3.connected.trianglepath.dotted",
                              action: #selector(menuSpawnSubagent)))
        menu.addItem(makeItem("Schedule…", symbol: "clock", action: #selector(menuSchedule)))

        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 0, y: plusButton.bounds.height + 6),
                   in: plusButton)
    }

    private func makeItem(_ title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func menuAttachFiles() { delegate?.composerAttachFilesRequested() }
    @objc private func menuAttachImage() { delegate?.composerAttachImageRequested() }
    @objc private func menuAddLink() { delegate?.composerAddLinkRequested() }
    @objc private func menuSpawnSubagent() { delegate?.composerSpawnSubagentRequested() }
    @objc private func menuSchedule() { delegate?.composerScheduleRequested() }

    @objc private func menuInsertSkill(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        delegate?.composerInsertSkillRequested(name)
    }

    // MARK: - Text plumbing

    func textDidChange(_ notification: Notification) {
        textDidChangeInternally()
    }

    private func textDidChangeInternally() {
        let height = min(max(textView.contentHeight, 30), 150)
        if abs(textHeightConstraint.constant - height) > 0.5 {
            textHeightConstraint.constant = height
        }
        textView.needsDisplay = true
        updateSendEnabled()
        delegate?.composerTextDidChange()
    }

    private func updateSendEnabled() {
        sendButton.isEnabled = isRunning
            || !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false // ⇧Return -> newline
            }
            submitTapped()
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            delegate?.composerCycleModeRequested()
            return true
        }
        return false
    }
}

// MARK: - Buttons

/// 28×24 rounded bezel button (design's small square composer buttons).
final class ChatBezelButton: NSButton {
    convenience init(symbolName: String) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: 12, weight: .medium)
        commonSetup()
    }

    convenience init(text: String) {
        self.init(frame: .zero)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.monoFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Theme.tx2,
        ])
        commonSetup()
    }

    private func commonSetup() {
        isBordered = false
        setButtonType(.momentaryChange)
        contentTintColor = Theme.tx2
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.line2.cgColor
    }
}

/// 30×24 accent square: ↑ to send, stop square while a turn runs.
final class ChatSendButton: NSButton {
    var showsStop = false {
        didSet {
            image = NSImage(systemSymbolName: showsStop ? "stop.fill" : "arrow.up",
                            accessibilityDescription: showsStop ? "Stop" : "Send")
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")
        symbolConfiguration = .init(pointSize: 11, weight: .bold)
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let base = Theme.acc
        layer?.backgroundColor = isEnabled
            ? base.cgColor
            : base.withAlphaComponent(0.35).cgColor
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }
}
