//
//  SkillsGridViewController.swift
//  hermes-native-app
//
//  SKILLS tab: 2-column grid of skill cards (mono name + "used N×" chip when
//  the learning graph has usage data + description) from GET /api/skills.
//  Context menu toggles a skill via PUT /api/skills/toggle.
//

import AppKit
import Combine

final class SkillsGridViewController: SkillsPageViewController {
    private let grid = NSStackView()
    private let statusField = SkillsUI.placeholder("Loading skills…")
    private var loadedOnce = false

    override func viewDidLoad() {
        super.viewDidLoad()

        addFullWidth(SkillsUI.title("Skills"), spacingAfter: 5)
        addFullWidth(
            SkillsUI.blurb("Procedural memory Hermes created from experience. They self-improve as they're used."),
            spacingAfter: 22
        )

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 13
        addFullWidth(grid)

        addFullWidth(statusField)

        store.$skills
            .combineLatest(hub.$skillUseCounts)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] skills, usage in
                self?.render(skills: skills, usage: usage)
            }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task {
            await store.refreshSkills()
            await hub.refreshLearning()
        }
    }

    private func render(skills: [Skill], usage: [String: Int]) {
        if !skills.isEmpty { loadedOnce = true }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !skills.isEmpty else {
            statusField.isHidden = false
            statusField.stringValue = loadedOnce || store.connectionState.isReady
                ? "No skills yet — Hermes saves procedural memory here as it works."
                : "Loading skills…"
            return
        }
        statusField.isHidden = true

        // 2-column grid built from equal-width horizontal rows.
        var index = 0
        while index < skills.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 13
            row.translatesAutoresizingMaskIntoConstraints = false

            for column in 0..<2 {
                if index + column < skills.count {
                    let skill = skills[index + column]
                    row.addArrangedSubview(makeCard(for: skill, useCount: usage[skill.name]))
                } else {
                    row.addArrangedSubview(NSView())
                }
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            index += 2
        }
    }

    private func makeCard(for skill: Skill, useCount: Int?) -> NSView {
        let card = SkillsCardView()

        let name = NSTextField(labelWithString: skill.name)
        name.font = Theme.monoFont(ofSize: 13, weight: .medium)
        name.textColor = Theme.tx
        name.lineBreakMode = .byTruncatingTail

        let headerRow = NSStackView(views: [name, NSView()])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8

        // "used N×" chip only when the learning graph reports real usage.
        if let useCount, useCount > 0 {
            headerRow.addArrangedSubview(SkillsPillView(
                text: "used \(useCount)×",
                textColor: Theme.tx2,
                fill: Theme.bgInset2
            ))
        }

        let desc = NSTextField(wrappingLabelWithString: skill.description)
        desc.font = NSFont.systemFont(ofSize: 12.5)
        desc.textColor = Theme.tx2
        desc.isSelectable = false
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Trailing flexible spacer absorbs vertical slack when a row stretches
        // this card to match a taller sibling, so title+description stay packed
        // at the top instead of the description drifting to the card's bottom.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        spacer.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let content = NSStackView(views: [headerRow, desc, spacer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        content.setCustomSpacing(0, after: desc)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        content.pin(to: card, insets: NSEdgeInsets(top: 16, left: 17, bottom: 16, right: 17))
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            desc.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])

        card.alphaValue = skill.enabled ? 1 : 0.55

        let menu = NSMenu()
        let item = NSMenuItem(
            title: skill.enabled ? "Disable Skill" : "Enable Skill",
            action: #selector(toggleSkill(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = skill
        menu.addItem(item)
        card.menu = menu

        card.toolTip = skill.category.isEmpty ? skill.name : "\(skill.name) · \(skill.category)"
        return card
    }

    @objc private func toggleSkill(_ sender: NSMenuItem) {
        guard let skill = sender.representedObject as? Skill else { return }
        Task {
            if let error = await hub.setSkillEnabled(skill.name, !skill.enabled) {
                SkillsUI.presentError(error, in: view.window)
            }
        }
    }
}
