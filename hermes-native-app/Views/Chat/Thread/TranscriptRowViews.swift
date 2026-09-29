import AppKit

// Shared row plumbing + the simple turn renderers (user / system / divider).

// MARK: - Platform badges

/// Monochrome monogram letters for message sources (never brand colors).
enum ChatPlatformBadge {
    static func monogram(for source: String?) -> String {
        switch source?.lowercased() {
        case "telegram": return "T"
        case "discord": return "D"
        case "slack": return "S"
        case "signal": return "§"
        case "whatsapp": return "W"
        case "email", "imap", "smtp": return "@"
        case "cli", "tui", "terminal": return ">"
        default: return "›"
        }
    }

    static func displayName(for source: String) -> String {
        switch source.lowercased() {
        case "cli", "tui": return source.uppercased()
        case "email": return "Email"
        default: return source.prefix(1).uppercased() + source.dropFirst().lowercased()
        }
    }

    /// Sources that count as messaging platforms (continuity divider trigger).
    static func isMessagingPlatform(_ source: String?) -> Bool {
        guard let source = source?.lowercased() else { return false }
        return ["telegram", "discord", "slack", "signal", "whatsapp", "email", "imessage"].contains(source)
    }
}

// MARK: - Base row

/// One row of the transcript stack. Subclasses render a specific
/// `TranscriptItem.Kind` and update in place when the item mutates.
class ChatTranscriptRowView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func canRepresent(_ kind: TranscriptItem.Kind) -> Bool { false }
    func update(_ kind: TranscriptItem.Kind) {}
}

// MARK: - Small shared pieces

/// Multi-line label that plays nicely with Auto Layout width changes.
final class ChatWrappingLabel: NSTextField {
    convenience init(text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular,
                     color: NSColor? = nil, mono: Bool = false) {
        self.init(wrappingLabelWithString: text)
        font = mono ? Theme.monoFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        textColor = color ?? Theme.tx
        isSelectable = true
        allowsEditingTextAttributes = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// Rounded card whose fill/stroke re-resolve on every appearance pass.
class ChatCardView: NSView {
    var fill: () -> NSColor
    var stroke: () -> NSColor?
    var radius: CGFloat

    init(fill: @escaping () -> NSColor,
         stroke: (() -> NSColor?)? = nil,
         radius: CGFloat = 12) {
        self.fill = fill
        self.stroke = stroke ?? { Theme.line }
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.backgroundColor = fill().cgColor
        layer?.borderColor = (stroke() ?? .clear).cgColor
    }
}

/// Non-editable text view that reports its laid-out height as intrinsic size
/// so streamed appends stay cheap (`textStorage` mutation, no re-set).
final class ChatSelfSizingTextView: NSTextView {
    static func make() -> ChatSelfSizingTextView {
        let view = ChatSelfSizingTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return super.intrinsicContentSize
        }
        manager.ensureLayout(for: container)
        let height = ceil(manager.usedRect(for: container).height)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 16))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateIntrinsicContentSize()
    }
}

// MARK: - User message row

/// Right-aligned inset card; leading `@file:` / `@image:` / `@folder:` tokens
/// render as attachment chips; "via <source> · time" tag when the message
/// arrived from another platform.
final class ChatUserMessageRowView: ChatTranscriptRowView {
    private let card = ChatCardView(fill: { Theme.bgInset }, stroke: { Theme.line }, radius: 15)
    private let chipsStack = NSStackView()
    private let textLabel = ChatWrappingLabel(size: 13.5)
    private let viaRow = NSStackView()
    private let viaChip = MonogramChipView(letter: "›")
    private let viaLabel = NSTextField.label(size: 11, color: Theme.tx3)
    private var lastText: String?

    override init() {
        super.init()

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false

        chipsStack.orientation = .horizontal
        chipsStack.spacing = 8
        column.addArrangedSubview(chipsStack)
        column.addArrangedSubview(textLabel)
        textLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true

        card.addSubview(column)
        addSubview(card)

        viaRow.orientation = .horizontal
        viaRow.spacing = 6
        viaRow.translatesAutoresizingMaskIntoConstraints = false
        viaRow.addArrangedSubview(viaChip)
        viaRow.addArrangedSubview(viaLabel)
        addSubview(viaRow)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            card.topAnchor.constraint(equalTo: topAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),

            viaRow.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
            viaRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            viaRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func canRepresent(_ kind: TranscriptItem.Kind) -> Bool {
        if case .user = kind { return true }
        return false
    }

    override func update(_ kind: TranscriptItem.Kind) {
        guard case .user(let message) = kind else { return }

        if message.text != lastText {
            lastText = message.text
            let (attachments, body) = Self.splitAttachments(message.text)
            textLabel.stringValue = body
            chipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for attachment in attachments.prefix(4) {
                chipsStack.addArrangedSubview(ChatAttachmentChipView(token: attachment))
            }
            chipsStack.isHidden = attachments.isEmpty
        }

        let source = message.source?.lowercased()
        if let source, source != "desktop" {
            viaChip.letter = ChatPlatformBadge.monogram(for: source)
            var tag = "via \(ChatPlatformBadge.displayName(for: source))"
            if let timestamp = message.timestamp {
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                tag += " · \(formatter.string(from: timestamp))"
            }
            viaLabel.stringValue = tag
            viaRow.isHidden = false
        } else {
            viaRow.isHidden = true
        }
    }

    /// Pull leading `@file:` / `@image:` / `@folder:` tokens off the text.
    static func splitAttachments(_ text: String) -> (attachments: [String], body: String) {
        var attachments: [String] = []
        var rest: [Substring] = []
        var stillLeading = true
        for token in text.split(separator: " ", omittingEmptySubsequences: false) {
            if stillLeading,
               token.hasPrefix("@file:") || token.hasPrefix("@image:") || token.hasPrefix("@folder:") {
                attachments.append(String(token))
            } else {
                if !token.isEmpty { stillLeading = false }
                rest.append(token)
            }
        }
        let body = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (attachments, body)
    }
}

/// Icon tile + filename + uppercased extension chip for an `@…:` token.
private final class ChatAttachmentChipView: NSView {
    init(token: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1

        let kind: String
        let path: String
        if let colon = token.firstIndex(of: ":") {
            kind = String(token[token.index(after: token.startIndex)..<colon])
            path = String(token[token.index(after: colon)...])
        } else {
            kind = "file"
            path = token
        }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.uppercased()

        let symbol: String
        switch kind {
        case "image": symbol = "photo"
        case "folder": symbol = "folder"
        default: symbol = "doc"
        }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = Theme.tx2
        icon.wantsLayer = true
        icon.translatesAutoresizingMaskIntoConstraints = false

        let iconTile = ChatCardView(fill: { Theme.bgInset2 }, stroke: { nil }, radius: 6)
        iconTile.addSubview(icon)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = Theme.tx
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1

        let metaLabel = NSTextField.label(ext.isEmpty ? kind.uppercased() : ext, size: 10.5, color: Theme.tx3)

        let textColumn = NSStackView(views: [nameLabel, metaLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1

        let row = NSStackView(views: [iconTile, textColumn])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 30),
            iconTile.heightAnchor.constraint(equalToConstant: 30),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.line2.cgColor
    }
}

// MARK: - System / status / error row

/// `.system(...)` rows: "Error: …" renders as a danger row, everything else
/// as a quiet centered status line (compaction notices, steer confirmations).
final class ChatSystemRowView: ChatTranscriptRowView {
    private let icon = NSImageView()
    private let label = ChatWrappingLabel(size: 12)
    private let row = NSStackView()
    private var centerConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!

    override init() {
        super.init()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)

        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        addSubview(row)

        centerConstraint = row.centerXAnchor.constraint(equalTo: centerXAnchor)
        leadingConstraint = row.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            centerConstraint,
        ])
    }

    override func canRepresent(_ kind: TranscriptItem.Kind) -> Bool {
        if case .system = kind { return true }
        return false
    }

    override func update(_ kind: TranscriptItem.Kind) {
        guard case .system(let text) = kind else { return }
        if text.hasPrefix("Error:") {
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
            icon.contentTintColor = Theme.danger
            label.stringValue = String(text.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
            label.textColor = Theme.danger
            centerConstraint.isActive = false
            leadingConstraint.isActive = true
        } else {
            icon.isHidden = true
            label.stringValue = text
            label.textColor = Theme.tx3
            leadingConstraint.isActive = false
            centerConstraint.isActive = true
        }
    }
}

// MARK: - Divider row

/// `— (T) Continued from Telegram — picked up here on your Mac —` style pill
/// between hairlines. Also used for `.divider(String)` transcript items.
final class ChatDividerRowView: ChatTranscriptRowView {
    private let chip = MonogramChipView(letter: "›")
    private let label = NSTextField(labelWithString: "")

    override init() {
        super.init()

        let leftLine = ChatHairlineView()
        let rightLine = ChatHairlineView()

        label.font = NSFont.systemFont(ofSize: 11.5)
        label.textColor = Theme.tx2
        label.lineBreakMode = .byTruncatingTail

        let pill = ChatCardView(fill: { Theme.bgInset }, stroke: { Theme.line }, radius: 13)
        let pillContent = NSStackView(views: [chip, label])
        pillContent.orientation = .horizontal
        pillContent.spacing = 7
        pillContent.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillContent)

        let row = NSStackView(views: [leftLine, pill, rightLine])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        leftLine.widthAnchor.constraint(equalTo: rightLine.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            pillContent.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            pillContent.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            pillContent.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -11),
            pillContent.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    override func canRepresent(_ kind: TranscriptItem.Kind) -> Bool {
        if case .divider = kind { return true }
        return false
    }

    override func update(_ kind: TranscriptItem.Kind) {
        guard case .divider(let text) = kind else { return }
        configure(text: text, monogram: "›")
    }

    func configure(text: String, monogram: String) {
        label.stringValue = text
        chip.letter = monogram
    }
}

/// 1pt hairline in Theme.line.
final class ChatHairlineView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.line.cgColor }
}
