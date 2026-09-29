//
//  SkillsToolsViewController.swift
//  hermes-native-app
//
//  TOOLS & MCP tab: one card listing toolsets (GET /api/tools/toolsets) and
//  MCP servers (GET /api/mcp/servers). Each row: status dot (green when
//  enabled) + name + detail + NSSwitch wired to
//  PUT /api/tools/toolsets/{name} / PUT /api/mcp/servers/{name}/enabled.
//

import AppKit
import Combine

final class SkillsToolsViewController: SkillsPageViewController {

    private let blurbField = SkillsUI.blurb("Tools across toolsets, plus any MCP server.")
    private let card = SkillsCardView()
    private let listStack = NSStackView()
    private let statusField = SkillsUI.placeholder("Loading tools…")
    private var switchHolders: [SkillsSwitchActionHolder] = []

    override func viewDidLoad() {
        super.viewDidLoad()

        addFullWidth(SkillsUI.title("Tools & MCP"), spacingAfter: 5)
        addFullWidth(blurbField, spacingAfter: 22)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(listStack)
        listStack.pin(to: card)
        addFullWidth(card)

        addFullWidth(statusField)

        hub.$toolsets
            .combineLatest(hub.$mcpServers, hub.$toolsLoaded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] toolsets, servers, loaded in
                self?.render(toolsets: toolsets, servers: servers, loaded: loaded)
            }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await hub.refreshTools() }
    }

    private func render(toolsets: [ToolsetInfo], servers: [SkillsMcpServer], loaded: Bool) {
        let totalTools = hub.totalToolsetToolCount
        if totalTools > 0 {
            blurbField.stringValue = servers.isEmpty
                ? "\(totalTools) tools across toolsets, plus any MCP server."
                : "\(totalTools)+ tools across toolsets, plus any MCP server."
        } else {
            blurbField.stringValue = "Tools across toolsets, plus any MCP server."
        }

        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switchHolders.removeAll()

        let rowCount = toolsets.count + servers.count
        guard rowCount > 0 else {
            card.isHidden = true
            statusField.isHidden = false
            statusField.stringValue = loaded
                ? "The backend reported no toolsets or MCP servers."
                : "Loading tools…"
            return
        }
        card.isHidden = false
        statusField.isHidden = true

        var index = 0
        for toolset in toolsets {
            let detailParts: [String] = {
                var parts: [String] = []
                if !toolset.tools.isEmpty { parts.append("\(toolset.tools.count) tools") }
                if !toolset.description.isEmpty { parts.append(toolset.description) }
                if !toolset.configured { parts.append("not configured") }
                return parts
            }()
            appendRow(
                name: toolset.label.isEmpty ? toolset.name : toolset.label,
                detail: detailParts.joined(separator: " · "),
                enabled: toolset.enabled,
                isLast: index == rowCount - 1
            ) { [weak self] enabled in
                self?.toggleToolset(toolset.name, enabled: enabled)
            }
            index += 1
        }
        for server in servers {
            let detail: String
            if let count = server.toolCount {
                detail = "MCP · \(count) tools"
            } else if server.transport.isEmpty {
                detail = "MCP server"
            } else {
                detail = "MCP · \(server.transport)"
            }
            appendRow(
                name: server.name,
                detail: detail,
                enabled: server.enabled,
                isLast: index == rowCount - 1
            ) { [weak self] enabled in
                self?.toggleMcp(server.name, enabled: enabled)
            }
            index += 1
        }
    }

    private func appendRow(
        name: String,
        detail: String,
        enabled: Bool,
        isLast: Bool,
        onToggle: @escaping (Bool) -> Void
    ) {
        let dot = SkillsStatusDotView(color: enabled ? Theme.ok : Theme.tx3)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 13.5)
        nameLabel.textColor = Theme.tx
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = Theme.tx3
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = enabled ? .on : .off
        let holder = SkillsSwitchActionHolder(onToggle)
        toggle.target = holder
        toggle.action = #selector(SkillsSwitchActionHolder.switchChanged(_:))
        switchHolders.append(holder)

        let row = NSStackView(views: [dot, nameLabel, detailLabel, NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13
        row.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        row.pin(to: box, insets: NSEdgeInsets(top: 13, left: 17, bottom: 13, right: 17))

        listStack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        if !isLast {
            let line = HairlineView()
            listStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func toggleToolset(_ name: String, enabled: Bool) {
        Task {
            if let error = await hub.setToolsetEnabled(name, enabled) {
                SkillsUI.presentError(error, in: view.window)
            }
        }
    }

    private func toggleMcp(_ name: String, enabled: Bool) {
        Task {
            if let error = await hub.setMcpServerEnabled(name, enabled) {
                SkillsUI.presentError(error, in: view.window)
            }
        }
    }
}
