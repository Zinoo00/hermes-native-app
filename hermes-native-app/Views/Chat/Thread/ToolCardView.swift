import AppKit

/// Terminal-style tool execution card — dark even in light mode (design rule:
/// terminals/code stay dark). Header: spinner/status glyph + mono name +
/// context, right-aligned "running" / "✓ done" / "failed". Body: mono excerpt
/// of args/result, or a +/− tinted inline diff when the tool produced one.
final class ChatToolCardRowView: ChatTranscriptRowView {

    // Fixed dark-terminal palette (intentionally not Theme-dynamic: the design
    // keeps these cards dark in both appearances).
    private static let bodyBackground = NSColor(hex: 0x151619)
    private static let headerBackground = NSColor(hex: 0x1E1E20)
    private static let mutedText = NSColor(hex: 0x8F8F97)
    private static let dimText = NSColor(hex: 0x65656D)
    private static let brightText = NSColor(hex: 0xCFCFD4)
    private static let diffAdd = NSColor(hex: 0x9FCF8F)
    private static let diffRemove = NSColor(hex: 0xE8A0A0)

    private let spinner = NSProgressIndicator()
    private let statusGlyph = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyLabel = ChatWrappingLabel(size: 11.5, mono: true)
    private let headerView = NSView()
    private var lastBodyKey = ""

    override init() {
        super.init()
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        // Force dark resolution for any system-drawn subviews (spinner).
        appearance = NSAppearance(named: .darkAqua)

        headerView.wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.constrainSize(NSSize(width: 14, height: 14))

        statusGlyph.font = Theme.monoFont(ofSize: 11, weight: .semibold)
        statusGlyph.alignment = .center

        nameLabel.font = Theme.monoFont(ofSize: 12)
        nameLabel.textColor = NSColor(hex: 0x9B9BA3)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        contextLabel.font = Theme.monoFont(ofSize: 12)
        contextLabel.textColor = NSColor(hex: 0x82828A)
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = Self.dimText
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerStack = NSStackView(views: [spinner, statusGlyph, nameLabel, contextLabel, NSView(), statusLabel])
        headerStack.orientation = .horizontal
        headerStack.spacing = 9
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerStack)

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.isSelectable = true
        bodyLabel.textColor = Self.mutedText

        addSubview(headerView)
        addSubview(separator)
        addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 9),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -9),

            separator.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            bodyLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 11),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Self.bodyBackground.cgColor
        layer?.borderColor = Theme.line.cgColor
        headerView.layer?.backgroundColor = Self.headerBackground.cgColor
    }

    override func canRepresent(_ kind: TranscriptItem.Kind) -> Bool {
        guard case .tool(let card) = kind else { return false }
        return !ChatLearningPillRowView.isLearningEvent(card)
    }

    override func update(_ kind: TranscriptItem.Kind) {
        guard case .tool(let card) = kind else { return }

        nameLabel.stringValue = card.name
        contextLabel.stringValue = card.context ?? ""
        contextLabel.isHidden = (card.context ?? "").isEmpty

        switch card.status {
        case .running:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusGlyph.isHidden = true
            statusLabel.stringValue = "running"
            statusLabel.textColor = Self.dimText
        case .generating:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusGlyph.isHidden = true
            statusLabel.stringValue = "generating…"
            statusLabel.textColor = Self.dimText
        case .complete:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusGlyph.isHidden = false
            statusGlyph.stringValue = "✓"
            statusGlyph.textColor = Theme.ok
            statusLabel.stringValue = durationSuffix(card, base: "✓ done")
            statusLabel.textColor = Theme.ok
        case .failed:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusGlyph.isHidden = false
            statusGlyph.stringValue = "✕"
            statusGlyph.textColor = Self.diffRemove
            statusLabel.stringValue = "failed"
            statusLabel.textColor = Self.diffRemove
        }

        renderBody(card)
    }

    private func durationSuffix(_ card: ToolCard, base: String) -> String {
        guard let seconds = card.durationSeconds, seconds > 0.05 else { return base }
        if seconds < 10 { return base + String(format: " · %.1fs", seconds) }
        return base + String(format: " · %.0fs", seconds)
    }

    private func renderBody(_ card: ToolCard) {
        // Cheap change detection so streaming siblings don't re-layout this card.
        let key = [card.inlineDiff ?? "", card.resultText ?? "", card.argsText ?? "",
                   card.progressPreview ?? "", card.summary ?? "",
                   String(describing: card.status)].joined(separator: "\u{1}")
        guard key != lastBodyKey else { return }
        lastBodyKey = key

        if let diff = card.inlineDiff, !diff.isEmpty {
            bodyLabel.attributedStringValue = Self.attributedDiff(Self.clip(diff))
            bodyLabel.isHidden = false
            return
        }
        var text = ""
        if let result = card.resultText, !result.isEmpty {
            text = result
        } else if let summary = card.summary, !summary.isEmpty {
            text = summary
        } else if let preview = card.progressPreview, !preview.isEmpty {
            text = preview
        } else if let args = card.argsText, !args.isEmpty {
            text = args
        } else if !card.args.isNull {
            text = card.args.encodedString()
        }
        text = Self.clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
        bodyLabel.isHidden = text.isEmpty
        bodyLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Theme.monoFont(ofSize: 11.5),
            .foregroundColor: Self.mutedText,
        ])
    }

    /// Keep the first `maxLines`; note how much was elided.
    private static func clip(_ text: String, maxLines: Int = 18, maxChars: Int = 4000) -> String {
        var clipped = text
        if clipped.count > maxChars {
            clipped = String(clipped.prefix(maxChars))
        }
        let lines = clipped.components(separatedBy: "\n")
        guard lines.count > maxLines || clipped.count < text.count else { return clipped }
        let head = lines.prefix(maxLines).joined(separator: "\n")
        let hidden = max(lines.count - maxLines, 0)
        return head + (hidden > 0 ? "\n… +\(hidden) more lines" : "\n…")
    }

    private static func attributedDiff(_ diff: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let font = Theme.monoFont(ofSize: 11.5)
        let lines = diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let color: NSColor
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@")
                || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                color = dimText
            } else if line.hasPrefix("+") {
                color = diffAdd
            } else if line.hasPrefix("-") {
                color = diffRemove
            } else if line.hasPrefix("…") {
                color = dimText
            } else {
                color = mutedText
            }
            output.append(NSAttributedString(
                string: index == lines.count - 1 ? line : line + "\n",
                attributes: [.font: font, .foregroundColor: color]))
        }
        return output
    }
}

/// Learning-loop event pill — shown instead of a terminal card when a
/// completed tool looks like the skill-save/learning loop
/// ("Learning loop — saved a new skill <name> · memory updated").
final class ChatLearningPillRowView: ChatTranscriptRowView {
    private let label = NSTextField(labelWithString: "")
    private let pill = ChatCardView(fill: { Theme.accSoft },
                                    stroke: { Theme.acc.withAlphaComponent(0.4) },
                                    radius: 10)
    private let icon = NSImageView()

    override init() {
        super.init()

        icon.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = Theme.acc

        label.font = NSFont.systemFont(ofSize: 12.5)
        label.textColor = Theme.tx
        label.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(row)
        addSubview(pill)

        row.pin(to: pill, insets: NSEdgeInsets(top: 8, left: 13, bottom: 8, right: 13))
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func canRepresent(_ kind: TranscriptItem.Kind) -> Bool {
        guard case .tool(let card) = kind else { return false }
        return Self.isLearningEvent(card)
    }

    override func update(_ kind: TranscriptItem.Kind) {
        guard case .tool(let card) = kind else { return }
        let text = NSMutableAttributedString(
            string: "Learning loop — saved a new skill ",
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.tx])
        if let skillName = Self.skillName(card) {
            text.append(NSAttributedString(
                string: skillName,
                attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                             .foregroundColor: Theme.tx]))
        }
        text.append(NSAttributedString(
            string: "  · memory updated",
            attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.tx3]))
        label.attributedStringValue = text
        icon.contentTintColor = Theme.acc
    }

    /// Heuristic: tool names like `skill_save` / `save_skill` / `skill.create`.
    static func isLearningEvent(_ card: ToolCard) -> Bool {
        let name = card.name.lowercased()
        guard name.contains("skill") else { return false }
        return name.contains("save") || name.contains("create")
            || name.contains("learn") || name.contains("write")
    }

    private static func skillName(_ card: ToolCard) -> String? {
        for key in ["name", "skill_name", "skill", "title"] {
            if let value = card.args[key].string, !value.isEmpty { return value }
        }
        if let summary = card.summary, !summary.isEmpty { return summary }
        return nil
    }
}
