//
//  SkillsSidebarViewController.swift
//  hermes-native-app
//
//  Skills hub source list: IDENTITY (Personality / Context / Memory),
//  LIBRARY (Skills · Commands), CONNECTIONS (Messaging · Tools & MCP).
//  Selection = solid accent row with white text. Counts bind to live
//  backend data. SidebarFooterView is pinned to the bottom.
//

import AppKit
import Combine

final class SkillsSidebarViewController: NSViewController {
    private let store = AppEnvironment.shared.store
    private let hub = SkillsHubModel.shared
    private var cancellables = Set<AnyCancellable>()
    private var rows: [SkillsTab: SkillsNavRowView] = [:]

    override func loadView() {
        let root = NSView()

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 0
        nav.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nav)

        for group in SkillsNavGroup.all {
            let header = SectionLabelField(group.label)
            let headerBox = NSView()
            headerBox.translatesAutoresizingMaskIntoConstraints = false
            header.translatesAutoresizingMaskIntoConstraints = false
            headerBox.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 14),
                header.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 12),
                header.bottomAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: -4),
            ])
            nav.addArrangedSubview(headerBox)
            headerBox.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true

            let rowsStack = NSStackView()
            rowsStack.orientation = .vertical
            rowsStack.alignment = .leading
            rowsStack.spacing = 1
            rowsStack.translatesAutoresizingMaskIntoConstraints = false
            for tab in group.tabs {
                let row = SkillsNavRowView(tab: tab)
                row.onClick = { [weak self] tab in self?.hub.tab = tab }
                rows[tab] = row
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
            let rowsBox = NSView()
            rowsBox.translatesAutoresizingMaskIntoConstraints = false
            rowsBox.addSubview(rowsStack)
            rowsStack.pin(to: rowsBox, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
            nav.addArrangedSubview(rowsBox)
            rowsBox.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }

        let footer = SidebarFooterView(store: store)
        root.addSubview(footer)

        // fullSizeContentView window: keep the nav below the unified toolbar.
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nav.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
    }

    private func bind() {
        hub.$tab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                guard let self else { return }
                for (rowTab, row) in self.rows {
                    row.isSelectedRow = rowTab == tab
                }
            }
            .store(in: &cancellables)

        store.$skills
            .receive(on: DispatchQueue.main)
            .sink { [weak self] skills in
                self?.rows[.skills]?.setCount(skills.isEmpty ? nil : "\(skills.count)")
            }
            .store(in: &cancellables)

        hub.$customCommands
            .combineLatest(hub.$builtinCommands)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] custom, builtin in
                let total = custom.count + builtin.count
                self?.rows[.commands]?.setCount(total > 0 ? "\(total)" : nil)
            }
            .store(in: &cancellables)

        hub.$messagingCards
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cards in
                self?.rows[.messaging]?.setCount(cards.isEmpty ? nil : "\(cards.count)")
            }
            .store(in: &cancellables)

        hub.$toolsets
            .combineLatest(hub.$mcpServers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, servers in
                guard let self else { return }
                let toolTotal = self.hub.totalToolsetToolCount
                var count: String?
                if toolTotal > 0 {
                    // MCP servers add an unknown number of tools -> "N+".
                    count = servers.isEmpty ? "\(toolTotal)" : "\(toolTotal)+"
                } else if !servers.isEmpty {
                    count = "\(servers.count)"
                }
                self.rows[.tools]?.setCount(count)
            }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.rows.values.forEach { $0.needsDisplay = true }
        }
    }
}

// MARK: - Row

/// One source-list row: icon + label + trailing count. Selected rows fill
/// with the accent and flip text/icon to white (design source-list style).
final class SkillsNavRowView: NSControl {
    let tab: SkillsTab
    var onClick: ((SkillsTab) -> Void)?

    var isSelectedRow = false {
        didSet { applyColors() }
    }

    private let iconView = NSImageView()
    private let labelField: NSTextField
    private let countField = NSTextField(labelWithString: "")

    init(tab: SkillsTab) {
        self.tab = tab
        labelField = NSTextField(labelWithString: tab.title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        labelField.font = NSFont.systemFont(ofSize: 13)
        labelField.lineBreakMode = .byTruncatingTail
        countField.font = NSFont.systemFont(ofSize: 11.5)
        countField.isHidden = true

        let row = NSStackView(views: [iconView, labelField, NSView(), countField])
        row.orientation = .horizontal
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9))
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true

        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setCount(_ text: String?) {
        countField.stringValue = text ?? ""
        countField.isHidden = text == nil
    }

    private func applyColors() {
        if isSelectedRow {
            labelField.textColor = .white
            iconView.contentTintColor = .white
            countField.textColor = NSColor.white.withAlphaComponent(0.82)
        } else {
            labelField.textColor = Theme.tx
            iconView.contentTintColor = Theme.tx2
            countField.textColor = Theme.tx3
        }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isSelectedRow ? Theme.acc.cgColor : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(tab)
    }
}
