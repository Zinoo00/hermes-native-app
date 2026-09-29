//
//  SkillsCommandsViewController.swift
//  hermes-native-app
//
//  COMMANDS tab: CUSTOM (quick_commands from config.yaml, via the
//  commands.catalog "User commands" bucket) and BUILT-IN groups from the
//  commands.catalog RPC. The backend exposes no write path for creating or
//  editing custom commands, so "+ New command" and "Edit ›" are disabled
//  with explanatory tooltips. Built-in switches persist client-side only
//  (UserDefaults) — the gateway has no per-command disable API.
//

import AppKit
import Combine

final class SkillsCommandsViewController: SkillsPageViewController {

    private static let togglesKey = "hermes.skills.builtinCommandToggles"

    private let customCard = SkillsCardView()
    private let builtinCard = SkillsCardView()
    private let customStack = NSStackView()
    private let builtinStack = NSStackView()
    private let statusField = SkillsUI.placeholder("Loading commands…")
    private var toggles: [String: Bool] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        toggles = (UserDefaults.standard.dictionary(forKey: Self.togglesKey) as? [String: Bool]) ?? [:]

        // — Header row: title + "+ New command" (read-only backend -> disabled)
        let newCommand = NSButton(title: "+ New command", target: nil, action: nil)
        newCommand.isBordered = false
        newCommand.attributedTitle = NSAttributedString(
            string: "+ New command",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: Theme.tx3,
            ]
        )
        newCommand.isEnabled = false
        newCommand.toolTip = "Custom commands are quick_commands in config.yaml — the backend has no API to create them from here yet."

        let headerRow = NSStackView(views: [SkillsUI.title("Commands"), NSView(), newCommand])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        addFullWidth(headerRow, spacingAfter: 5)

        addFullWidth(
            SkillsUI.blurb("Slash commands you can type in any chat. Create your own shortcuts or toggle the built-ins."),
            spacingAfter: 22
        )

        // — CUSTOM
        addFullWidth(SectionLabelField("Custom"), spacingAfter: 12)
        configureListStack(customStack, in: customCard)
        addFullWidth(customCard, spacingAfter: 24)

        // — BUILT-IN
        addFullWidth(SectionLabelField("Built-in"), spacingAfter: 12)
        configureListStack(builtinStack, in: builtinCard)
        addFullWidth(builtinCard)

        addFullWidth(statusField)

        hub.$customCommands
            .combineLatest(hub.$builtinCommands, hub.$commandsLoaded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] custom, builtin, loaded in
                self?.render(custom: custom, builtin: builtin, loaded: loaded)
            }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await hub.refreshCommands() }
    }

    private func configureListStack(_ stack: NSStackView, in card: SkillsCardView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        stack.pin(to: card)
    }

    private func render(custom: [SkillsCommandEntry], builtin: [SkillsCommandEntry], loaded: Bool) {
        statusField.isHidden = loaded || !custom.isEmpty || !builtin.isEmpty

        customStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if custom.isEmpty {
            let empty = SkillsUI.placeholder(
                loaded
                    ? "No custom commands yet — define quick_commands in config.yaml."
                    : "Loading…"
            )
            empty.alignment = .left
            let box = padded(empty)
            customStack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: customStack.widthAnchor).isActive = true
        } else {
            for (index, entry) in custom.enumerated() {
                appendRow(makeCustomRow(entry), to: customStack, isLast: index == custom.count - 1)
            }
        }

        builtinStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switchHolders.removeAll()
        if builtin.isEmpty {
            let empty = SkillsUI.placeholder(loaded ? "The gateway reported no commands." : "Loading…")
            empty.alignment = .left
            let box = padded(empty)
            builtinStack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: builtinStack.widthAnchor).isActive = true
        } else {
            for (index, entry) in builtin.enumerated() {
                appendRow(makeBuiltinRow(entry), to: builtinStack, isLast: index == builtin.count - 1)
            }
        }
    }

    private func padded(_ view: NSView) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: 13),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -13),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 17),
            view.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -17),
        ])
        return box
    }

    private func appendRow(_ row: NSView, to stack: NSStackView, isLast: Bool) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if !isLast {
            let line = HairlineView()
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func nameField(_ text: String, accent: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Theme.monoFont(ofSize: 13, weight: .medium)
        field.textColor = accent ? Theme.acc : Theme.tx
        field.lineBreakMode = .byTruncatingTail
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    private func descField(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 12.5)
        field.textColor = Theme.tx2
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func makeCustomRow(_ entry: SkillsCommandEntry) -> NSView {
        let edit = NSTextField.label("Edit ›", size: 11.5, color: Theme.tx3)
        edit.toolTip = "Editing quick_commands isn't supported by the backend API — change config.yaml instead."

        let row = NSStackView(views: [nameField(entry.name, accent: true), descField(entry.detail), NSView(), edit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return padded(rowContent: row)
    }

    private func makeBuiltinRow(_ entry: SkillsCommandEntry) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = (toggles[entry.name] ?? true) ? .on : .off
        toggle.toolTip = "Per-app preference only — the gateway has no per-command disable API yet."
        let holder = SkillsSwitchActionHolder { [weak self] enabled in
            guard let self else { return }
            self.toggles[entry.name] = enabled
            UserDefaults.standard.set(self.toggles, forKey: Self.togglesKey)
        }
        toggle.target = holder
        toggle.action = #selector(SkillsSwitchActionHolder.switchChanged(_:))
        switchHolders.append(holder)

        let row = NSStackView(views: [nameField(entry.name, accent: false), descField(entry.detail), NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return padded(rowContent: row)
    }

    private var switchHolders: [SkillsSwitchActionHolder] = []

    private func padded(rowContent: NSStackView) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        rowContent.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rowContent)
        rowContent.pin(to: box, insets: NSEdgeInsets(top: 12, left: 17, bottom: 12, right: 17))
        return box
    }
}

/// Tiny target box so each NSSwitch row can carry its own closure.
final class SkillsSwitchActionHolder: NSObject {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    @objc func switchChanged(_ sender: NSSwitch) {
        handler(sender.state == .on)
    }
}
