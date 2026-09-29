import AppKit

/// Assistant turn: 24pt accent "A" avatar + markdown body, no bubble.
/// A collapsed "Thinking…" disclosure above the body reveals accumulated
/// reasoning text. Streaming appends plain-styled deltas into the text
/// storage; the finished message is re-rendered as markdown once.
final class ChatAssistantRowView: ChatTranscriptRowView {

    private let avatar = ChatAssistantAvatarView()
    private let bodyView = ChatSelfSizingTextView.make()
    private let reasoningToggle = NSButton()
    private let reasoningLabel = ChatWrappingLabel(size: 12, color: Theme.tx3)
    private let column = NSStackView()

    private var reasoningExpanded = false
    private var renderedPlainText = ""
    private var renderedAsMarkdown = false

    override init() {
        super.init()

        reasoningToggle.isBordered = false
        reasoningToggle.imagePosition = .imageLeading
        reasoningToggle.alignment = .left
        reasoningToggle.target = self
        reasoningToggle.action = #selector(toggleReasoning)
        reasoningToggle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        styleReasoningToggle()

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(reasoningToggle)
        column.addArrangedSubview(reasoningLabel)
        column.addArrangedSubview(bodyView)
        reasoningLabel.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -12).isActive = true
        bodyView.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        addSubview(avatar)
        addSubview(column)
        NSLayoutConstraint.activate([
            // Pin the avatar to a fixed 24×24 — its intrinsic size hugs too weakly
            // to resist stretching, and a stretched avatar pushes the text column
            // down to ~1 character per line.
            avatar.widthAnchor.constraint(equalToConstant: 24),
            avatar.heightAnchor.constraint(equalToConstant: 24),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            column.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        reasoningToggle.isHidden = true
        reasoningLabel.isHidden = true
    }

    override func canRepresent(_ kind: TranscriptItem.Kind) -> Bool {
        if case .assistant = kind { return true }
        return false
    }

    override func update(_ kind: TranscriptItem.Kind) {
        guard case .assistant(let message) = kind else { return }

        // Reasoning disclosure.
        let hasReasoning = !message.reasoning.isEmpty
        reasoningToggle.isHidden = !hasReasoning
        reasoningLabel.isHidden = !hasReasoning || !reasoningExpanded
        if hasReasoning, reasoningExpanded {
            if reasoningLabel.stringValue != message.reasoning {
                reasoningLabel.stringValue = message.reasoning
            }
        }

        // Body text.
        if message.isStreaming {
            if renderedAsMarkdown {
                // A fresh stream reused this row after a completed one — reset.
                bodyView.textStorage?.setAttributedString(ChatMarkdown.plain(message.text))
                renderedPlainText = message.text
                renderedAsMarkdown = false
            } else if message.text.hasPrefix(renderedPlainText) {
                let delta = String(message.text.dropFirst(renderedPlainText.count))
                if !delta.isEmpty {
                    bodyView.textStorage?.append(NSAttributedString(
                        string: delta, attributes: ChatMarkdown.plainAttributes()))
                    renderedPlainText = message.text
                }
            } else {
                bodyView.textStorage?.setAttributedString(ChatMarkdown.plain(message.text))
                renderedPlainText = message.text
            }
            bodyView.invalidateIntrinsicContentSize()
        } else if !renderedAsMarkdown || renderedPlainText != message.text {
            bodyView.textStorage?.setAttributedString(ChatMarkdown.render(message.text))
            renderedPlainText = message.text
            renderedAsMarkdown = true
            bodyView.invalidateIntrinsicContentSize()
        }
    }

    @objc private func toggleReasoning() {
        reasoningExpanded.toggle()
        reasoningLabel.isHidden = !reasoningExpanded
        styleReasoningToggle()
    }

    private func styleReasoningToggle() {
        let title = NSMutableAttributedString(
            string: "Thinking…",
            attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                         .foregroundColor: Theme.tx3])
        reasoningToggle.attributedTitle = title
        reasoningToggle.image = NSImage(
            systemSymbolName: reasoningExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
        reasoningToggle.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        reasoningToggle.contentTintColor = Theme.tx3
    }
}

/// 24pt rounded accent-soft square with an accent "A".
final class ChatAssistantAvatarView: NSView {
    private let label = NSTextField(labelWithString: "A")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        label.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = Theme.acc
        label.alignment = .center
        addSubview(label)
        label.center(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accSoft.cgColor
        label.textColor = Theme.acc
    }
}
