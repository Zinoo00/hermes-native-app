//
//  SkillsMemoryViewController.swift
//  hermes-native-app
//
//  MEMORY tab: search field over the curated memory list built from
//  /api/learning/graph memory nodes (MEMORY.md / USER.md chunks). Rows show
//  a neutral dot + text + provenance, with a hover-revealed red "Forget"
//  that DELETEs the node. Forget has no undo: the server cannot re-create a
//  deleted memory chunk.
//

import AppKit
import Combine

final class SkillsMemoryViewController: SkillsPageViewController, NSSearchFieldDelegate {

    private let searchField = NSSearchField()
    private let listStack = NSStackView()
    private let statusField = SkillsUI.placeholder("Loading memory…")

    private var query = ""

    override func viewDidLoad() {
        super.viewDidLoad()

        addFullWidth(SkillsUI.title("Memory"), spacingAfter: 5)
        addFullWidth(
            SkillsUI.blurb("What Hermes knows about you, curated across sessions with Honcho. Forget anything that's wrong."),
            spacingAfter: 18
        )

        searchField.placeholderString = "Search memory & past sessions"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        addFullWidth(searchField, spacingAfter: 22)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 9
        addFullWidth(listStack)

        addFullWidth(statusField)

        hub.$memoryEntries
            .combineLatest(hub.$memoryLoaded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries, loaded in
                self?.render(entries: entries, loaded: loaded)
            }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task { await hub.refreshLearning() }
    }

    func controlTextDidChange(_ obj: Notification) {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        render(entries: hub.memoryEntries, loaded: hub.memoryLoaded)
    }

    private func render(entries: [SkillsMemoryEntry], loaded: Bool) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let visible = entries.filter { entry in
            guard !query.isEmpty else { return true }
            let haystack = "\(entry.title) \(entry.body ?? "") \(entry.group)".lowercased()
            return haystack.contains(query)
        }

        guard !visible.isEmpty else {
            statusField.isHidden = false
            if !loaded {
                statusField.stringValue = "Loading memory…"
            } else if !query.isEmpty {
                statusField.stringValue = "No memories match “\(searchField.stringValue)”."
            } else {
                statusField.stringValue = "Nothing here yet — Hermes adds memories as it learns."
            }
            return
        }
        statusField.isHidden = true

        // Group rows by section label, preserving encounter order.
        var order: [String] = []
        var groups: [String: [SkillsMemoryEntry]] = [:]
        for entry in visible {
            if groups[entry.group] == nil { order.append(entry.group) }
            groups[entry.group, default: []].append(entry)
        }

        for (index, groupLabel) in order.enumerated() {
            let header = SectionLabelField(groupLabel)
            listStack.addArrangedSubview(header)
            if index > 0 {
                listStack.setCustomSpacing(22, after: listStack.arrangedSubviews[listStack.arrangedSubviews.count - 2])
            }
            listStack.setCustomSpacing(11, after: header)
            for entry in groups[groupLabel] ?? [] {
                let row = SkillsMemoryRowView(entry: entry) { [weak self] entry, row in
                    self?.forget(entry, row: row)
                }
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
    }

    private func forget(_ entry: SkillsMemoryEntry, row: SkillsMemoryRowView) {
        row.setBusy(true)
        Task {
            if let error = await hub.forgetMemory(id: entry.id) {
                row.setBusy(false)
                SkillsUI.presentError(error, in: view.window)
            }
            // On success the model publisher removes the row.
        }
    }
}

// MARK: - Row

/// Memory row card: neutral dot + text + provenance caption + hover-revealed
/// red Forget button.
private final class SkillsMemoryRowView: SkillsCardView {
    private let entry: SkillsMemoryEntry
    private let onForget: (SkillsMemoryEntry, SkillsMemoryRowView) -> Void
    private let forgetButton = NSButton(title: "Forget", target: nil, action: nil)
    private var trackingArea: NSTrackingArea?

    init(entry: SkillsMemoryEntry,
         onForget: @escaping (SkillsMemoryEntry, SkillsMemoryRowView) -> Void) {
        self.entry = entry
        self.onForget = onForget
        super.init(cornerRadius: 12)

        let dot = SkillsStatusDotView(color: Theme.tx3)

        let text = NSTextField(wrappingLabelWithString: entry.title)
        text.font = NSFont.systemFont(ofSize: 13.5)
        text.textColor = Theme.tx
        text.isSelectable = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let meta = NSTextField.label(entry.provenance, size: 11.5, color: Theme.tx3)

        let textStack = NSStackView(views: [text, meta])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5

        forgetButton.isBordered = false
        forgetButton.attributedTitle = NSAttributedString(
            string: "Forget",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: Theme.danger,
            ]
        )
        forgetButton.target = self
        forgetButton.action = #selector(forgetClicked)
        forgetButton.isHidden = true
        forgetButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, textStack, forgetButton])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 13
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        NSLayoutConstraint.activate([
            text.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
        ])

        if let body = entry.body, !body.isEmpty, body != entry.title {
            toolTip = body
        }
    }

    func setBusy(_ busy: Bool) {
        forgetButton.isEnabled = !busy
        alphaValue = busy ? 0.6 : 1
    }

    @objc private func forgetClicked() {
        onForget(entry, self)
    }

    // Hover reveal.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        forgetButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        forgetButton.isHidden = true
    }
}
