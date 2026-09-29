//
//  SkillsContextViewController.swift
//  hermes-native-app
//
//  CONTEXT tab (AGENTS.md): file-switcher pill row (<HERMES_HOME>/AGENTS.md
//  plus any user-added .md files, remembered in UserDefaults) over the shared
//  markdown doc card.
//

import AppKit
import Combine
import UniformTypeIdentifiers

final class SkillsContextViewController: SkillsPageViewController {

    private struct ContextFile: Equatable {
        let path: String
        let label: String
        let removable: Bool
    }

    private static let extraFilesKey = "hermes.skills.contextFiles"

    private let doc = SkillsDocEditorView()
    private let pillRow = NSStackView()
    private var files: [ContextFile] = []
    private var selectedPath: String?
    private var hermesHome: String?

    override func viewDidLoad() {
        super.viewDidLoad()

        addFullWidth(SkillsUI.title("Context"), spacingAfter: 5)
        addFullWidth(
            SkillsUI.blurb("AGENTS.md gives Hermes standing context about you, your systems, and how you work — loaded into every session."),
            spacingAfter: 17
        )

        pillRow.orientation = .horizontal
        pillRow.alignment = .centerY
        pillRow.spacing = 8
        addFullWidth(pillRow, spacingAfter: 16)

        doc.metaPrefix = "Context"
        doc.missingMessage = "This file doesn't exist yet."
        doc.createTitle = "Create AGENTS.md"
        doc.createContent = "# Context\n\n## Me\n\n## Stack\n\n## Conventions\n"
        addFullWidth(doc, spacingAfter: 11)

        let footer = NSTextField.label(
            "Changes here apply to Hermes everywhere — Telegram, Slack, CLI, and this app.",
            size: 11.5, color: Theme.tx3, wrapping: true
        )
        addFullWidth(footer)

        doc.presentWaiting(filename: "AGENTS.md")

        store.$backendStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildFileList() }
            .store(in: &cancellables)

        rebuildFileList()
        renderPills() // even with no files yet, show "+ Add file"
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuildFileList()
    }

    // MARK: - File list

    private func rebuildFileList() {
        var next: [ContextFile] = []
        let home = store.backendStatus?.hermesHome
        if let home, !home.isEmpty {
            hermesHome = home
            next.append(ContextFile(
                path: (home as NSString).appendingPathComponent("AGENTS.md"),
                label: "AGENTS.md",
                removable: false
            ))
        }
        for path in UserDefaults.standard.stringArray(forKey: Self.extraFilesKey) ?? [] {
            guard !next.contains(where: { $0.path == path }) else { continue }
            next.append(ContextFile(path: path, label: displayLabel(for: path), removable: true))
        }
        guard next != files else { return }
        files = next
        if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
            selectedPath = files.first?.path
        }
        renderPills()
        presentSelected()
    }

    private func displayLabel(for path: String) -> String {
        if let hermesHome, path.hasPrefix(hermesHome + "/") {
            return String(path.dropFirst(hermesHome.count + 1))
        }
        let parts = (path as NSString).pathComponents
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: "/")
        }
        return (path as NSString).lastPathComponent
    }

    private func renderPills() {
        pillRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for file in files {
            let pill = SkillsFilePillControl(label: file.label, selected: file.path == selectedPath)
            pill.onClick = { [weak self] in self?.select(path: file.path) }
            if file.removable {
                let menu = NSMenu()
                let item = NSMenuItem(title: "Remove from List", action: #selector(removeFile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = file.path
                menu.addItem(item)
                pill.menu = menu
                pill.toolTip = file.path
            }
            pillRow.addArrangedSubview(pill)
        }
        let add = SkillsAddFilePillControl()
        add.onClick = { [weak self] in self?.addFileClicked() }
        pillRow.addArrangedSubview(add)
        pillRow.addArrangedSubview(NSView())
    }

    private func select(path: String) {
        guard path != selectedPath else { return }
        selectedPath = path
        renderPills()
        presentSelected()
    }

    private func presentSelected() {
        guard let selectedPath,
              let file = files.first(where: { $0.path == selectedPath }) else {
            doc.presentWaiting(filename: "AGENTS.md")
            return
        }
        // Only the canonical AGENTS.md offers a create button; user-added
        // files were picked from disk and should exist already.
        doc.createTitle = file.removable ? nil : "Create AGENTS.md"
        doc.present(path: file.path, filename: file.label)
    }

    // MARK: - Add / remove

    private func addFileClicked() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.message = "Choose a Markdown context file for Hermes"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addFile(path: url.path)
        }
    }

    private func addFile(path: String) {
        var extras = UserDefaults.standard.stringArray(forKey: Self.extraFilesKey) ?? []
        if !extras.contains(path) {
            extras.append(path)
            UserDefaults.standard.set(extras, forKey: Self.extraFilesKey)
        }
        selectedPath = path
        files = [] // force rebuild
        rebuildFileList()
    }

    @objc private func removeFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var extras = UserDefaults.standard.stringArray(forKey: Self.extraFilesKey) ?? []
        extras.removeAll { $0 == path }
        UserDefaults.standard.set(extras, forKey: Self.extraFilesKey)
        if selectedPath == path { selectedPath = nil }
        files = []
        rebuildFileList()
    }
}

// MARK: - Pills

/// Mono file-switcher pill (selected: inset fill + hairline border).
private final class SkillsFilePillControl: NSControl {
    var onClick: (() -> Void)?
    private let selected: Bool

    init(label: String, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        let field = NSTextField(labelWithString: label)
        field.font = Theme.monoFont(ofSize: 12)
        field.textColor = selected ? Theme.tx : Theme.tx2
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        field.pin(to: self, insets: NSEdgeInsets(top: 6, left: 13, bottom: 6, right: 13))
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = selected ? Theme.bgInset2.cgColor : NSColor.clear.cgColor
        layer?.borderColor = selected ? Theme.line2.cgColor : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// "+ Add file" dashed pill.
private final class SkillsAddFilePillControl: NSControl {
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField.label("+ Add file", size: 12.5, color: Theme.tx3)
        addSubview(field)
        field.pin(to: self, insets: NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8
        )
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.lineWidth = 1
        Theme.line2.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
