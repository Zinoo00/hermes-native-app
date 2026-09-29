//
//  SkillsPersonalityViewController.swift
//  hermes-native-app
//
//  PERSONALITY tab (SOUL.md): caduceus icon tile + blurb, preset segmented
//  control (Default / Professional / Playful) that rewrites the document,
//  "Custom" tag when the content matches no preset, and the shared markdown
//  doc card bound to <HERMES_HOME>/SOUL.md via the backend fs API.
//

import AppKit
import Combine

final class SkillsPersonalityViewController: SkillsPageViewController {

    private struct SoulPreset {
        let label: String
        let text: String
    }

    // Canned presets transcribed 1:1 from the design source (`_soulPresets`).
    private static let presets: [SoulPreset] = [
        SoulPreset(label: "Default", text: """
        # SOUL

        You are Hermes — my personal agent. You live in my messages and on my machine, and you act on my behalf.

        ## Voice
        - Concise and direct. Lead with the answer, then the why.
        - Plain language. No corporate filler, no hedging.
        - Dry, understated humor is welcome — never performed.

        ## Disposition
        - Proactive: if something is worth doing, propose it.
        - Honest about uncertainty. Say what you don't know.
        - Protective of my time and my production systems.

        ## Operating principles
        - Explain risky shell commands before you run them.
        - Prefer reversible actions; snapshot before you change state.
        - When you learn something durable about me, remember it.
        """),
        SoulPreset(label: "Professional", text: """
        # SOUL

        You are Hermes — my agent and operator. You represent me; act with judgment and care.

        ## Voice
        - Precise and measured. Complete sentences, no slang.
        - Neutral and professional; warmth shows through competence, not chatter.

        ## Disposition
        - Methodical: state your assumptions, then proceed.
        - Conservative with production. Confirm before anything irreversible.

        ## Operating principles
        - Document what you change and why.
        - Escalate ambiguity instead of guessing.
        - Keep a clean audit trail of commands and approvals.
        """),
        SoulPreset(label: "Playful", text: """
        # SOUL

        Hey — I'm Hermes, your agent and partner in crime (the legal kind).

        ## Voice
        - Warm, quick, a little witty. I talk like a sharp friend, not a manual.
        - I celebrate the wins and keep the momentum up.

        ## Disposition
        - Eager and proactive — I'll grab the obvious next step.
        - Curious. I'll offer the fun option alongside the safe one.

        ## Operating principles
        - Still careful where it counts: I flag risky commands before running them.
        - I keep things reversible, and I remember what you like.
        """),
    ]

    private let doc = SkillsDocEditorView()
    private var presetControl: NSSegmentedControl!
    private let customTag = SkillsPillView(
        text: "Custom", textColor: Theme.tx2, fill: Theme.bgInset2, fontSize: 11, padH: 9, padV: 2
    )
    private var resolvedPath: String?

    override func viewDidLoad() {
        super.viewDidLoad()

        // — Header: icon tile ☤ + title + blurb
        let tile = SkillsAccentTileView()

        let title = SkillsUI.title("Personality")
        let blurb = SkillsUI.blurb(
            "SOUL.md defines how Hermes thinks, talks, and carries itself — the same voice on every platform."
        )
        let titleStack = NSStackView(views: [title, blurb])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let headerRow = NSStackView(views: [tile, titleStack])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 14
        addFullWidth(headerRow, spacingAfter: 17)
        blurb.widthAnchor.constraint(equalTo: titleStack.widthAnchor).isActive = true

        // — Preset row
        let presetLabel = NSTextField.label("Preset", size: 12.5, color: Theme.tx3)

        presetControl = NSSegmentedControl(
            labels: Self.presets.map(\.label),
            trackingMode: .selectOne,
            target: self,
            action: #selector(presetPicked(_:))
        )
        presetControl.selectedSegment = -1

        customTag.isHidden = true

        let presetRow = NSStackView(views: [presetLabel, presetControl, customTag, NSView()])
        presetRow.orientation = .horizontal
        presetRow.alignment = .centerY
        presetRow.spacing = 11
        addFullWidth(presetRow, spacingAfter: 16)

        // — Document card
        doc.metaPrefix = "Personality"
        doc.missingMessage = "SOUL.md doesn't exist yet — create it to give Hermes a voice."
        doc.createTitle = "Create SOUL.md"
        doc.createContent = Self.presets[0].text + "\n"
        doc.onTextChanged = { [weak self] text in
            self?.updatePresetSelection(for: text)
        }
        addFullWidth(doc, spacingAfter: 11)

        // — Footer caption
        let footer = NSTextField.label(
            "Changes here apply to Hermes everywhere — Telegram, Slack, CLI, and this app.",
            size: 11.5, color: Theme.tx3, wrapping: true
        )
        addFullWidth(footer)

        doc.presentWaiting(filename: "SOUL.md")

        store.$backendStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resolvePathIfNeeded() }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        resolvePathIfNeeded()
    }

    /// SOUL.md lives at <HERMES_HOME>/SOUL.md (seeded there by
    /// `hermes_cli/config.py` on first run).
    private func resolvePathIfNeeded() {
        guard resolvedPath == nil,
              let home = store.backendStatus?.hermesHome, !home.isEmpty else { return }
        let path = (home as NSString).appendingPathComponent("SOUL.md")
        resolvedPath = path
        doc.present(path: path, filename: "SOUL.md")
    }

    @objc private func presetPicked(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < Self.presets.count else { return }
        guard case .loaded = doc.state else {
            // No document loaded yet — nothing to rewrite.
            updatePresetSelection(for: doc.currentText)
            return
        }
        doc.replaceText(Self.presets[index].text + "\n")
    }

    private func updatePresetSelection(for text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = Self.presets.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }) {
            presetControl.selectedSegment = index
            customTag.isHidden = true
        } else {
            presetControl.selectedSegment = -1
            customTag.isHidden = normalized.isEmpty
        }
    }
}

/// 42pt rounded accent-wash tile with the caduceus glyph (design header tile).
private final class SkillsAccentTileView: NSView {
    let glyphField = NSTextField(labelWithString: "☤")
    private var cancellables = Set<AnyCancellable>()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11

        glyphField.font = NSFont.systemFont(ofSize: 22)
        glyphField.textColor = Theme.acc
        glyphField.alignment = .center
        glyphField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphField)
        constrainSize(NSSize(width: 42, height: 42))
        glyphField.center(in: self)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.glyphField.textColor = Theme.acc
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.accSoft.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
