import AppKit

/// Scrolling thread: NSScrollView + vertical stack of turn rows, recycled by
/// diffing on `TranscriptItem.id`. Keeps a continuity divider pinned at the
/// top, the SUBAGENTS card and a live status row pinned after the transcript,
/// and auto-scrolls while the user is at the bottom.
final class ChatTranscriptView: NSView {

    private let scrollView = NSScrollView()
    private let documentView = ChatFlippedDocumentView()
    private let stack = NSStackView()

    private let continuityRow = ChatDividerRowView()
    private let subagentsCard = ChatSubagentsCardView()
    private let statusRow = ChatThreadStatusRowView()

    private var rowViews: [UUID: ChatTranscriptRowView] = [:]
    private var columnWidthConstraint: NSLayoutConstraint!
    private static let maxColumnWidth: CGFloat = 780
    private static let sideMargin: CGFloat = 36

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let clip = scrollView.contentView
        // Readable column width, updated in layout() to min(780, available − 72).
        // A single REQUIRED constraint (never a soft preferred one): the wrapping
        // text rows have low horizontal compression resistance, so any non-required
        // width lets the whole column collapse to ~1 character per line. Because
        // the constant tracks the available width, this never over-constrains a
        // narrow window.
        let columnWidth = stack.widthAnchor.constraint(equalToConstant: Self.maxColumnWidth)
        columnWidth.priority = .required
        columnWidthConstraint = columnWidth

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: clip.topAnchor),
            documentView.widthAnchor.constraint(equalTo: clip.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 30),
            stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            columnWidth,
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
        ])

        // Fixed rows: [continuity divider][…transcript rows…][subagents][status]
        appendFixedRow(continuityRow)
        appendFixedRow(subagentsCard)
        appendFixedRow(statusRow)
        continuityRow.isHidden = true
        subagentsCard.isHidden = true
        statusRow.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // Fill to the readable max when there's room, else shrink to fit with
        // side margins so a narrow window never over-constrains the column.
        let available = scrollView.contentView.bounds.width
        let target = min(Self.maxColumnWidth, max(240, available - Self.sideMargin * 2))
        if abs(columnWidthConstraint.constant - target) > 0.5 {
            columnWidthConstraint.constant = target
        }
    }

    private func appendFixedRow(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - Content

    func apply(_ items: [TranscriptItem]) {
        let shouldStick = isNearBottom

        var seen = Set<UUID>()
        var index = 1 // arranged index 0 = continuity divider
        for item in items {
            seen.insert(item.id)
            var row = rowViews[item.id]
            if let existing = row, !existing.canRepresent(item.kind) {
                existing.removeFromSuperview()
                row = nil
            }
            let resolved: ChatTranscriptRowView
            if let row {
                resolved = row
            } else {
                resolved = Self.makeRow(for: item.kind)
                rowViews[item.id] = resolved
            }
            resolved.update(item.kind)
            position(resolved, at: index)
            index += 1
        }

        for (id, view) in rowViews where !seen.contains(id) {
            view.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }

        if shouldStick { scrollToBottomSoon() }
    }

    func setSubagents(_ rows: [SubagentRow]) {
        let shouldStick = isNearBottom
        subagentsCard.isHidden = rows.isEmpty
        if !rows.isEmpty { subagentsCard.update(rows: rows) }
        if shouldStick { scrollToBottomSoon() }
    }

    /// Trailing live-status row ("Thinking…", "Compacting context…", …).
    func setStatus(_ text: String?) {
        let shouldStick = isNearBottom
        statusRow.setText(text)
        if shouldStick { scrollToBottomSoon() }
    }

    /// Continuity divider ("Continued from Telegram — picked up here on your Mac").
    func setContinuity(text: String?, monogram: String) {
        if let text {
            continuityRow.configure(text: text, monogram: monogram)
            continuityRow.isHidden = false
        } else {
            continuityRow.isHidden = true
        }
    }

    func refreshAccent() {
        Self.markNeedsDisplayRecursively(self)
    }

    // MARK: - Row management

    private static func makeRow(for kind: TranscriptItem.Kind) -> ChatTranscriptRowView {
        switch kind {
        case .user: return ChatUserMessageRowView()
        case .assistant: return ChatAssistantRowView()
        case .tool(let card):
            return ChatLearningPillRowView.isLearningEvent(card)
                ? ChatLearningPillRowView() : ChatToolCardRowView()
        case .system: return ChatSystemRowView()
        case .divider: return ChatDividerRowView()
        }
    }

    private func position(_ row: ChatTranscriptRowView, at index: Int) {
        let arranged = stack.arrangedSubviews
        if index < arranged.count, arranged[index] === row { return }
        if row.superview === stack {
            row.removeFromSuperview()
        }
        stack.insertArrangedSubview(row, at: min(index, stack.arrangedSubviews.count))
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - Scrolling

    private var isNearBottom: Bool {
        let clip = scrollView.contentView
        let bottomGap = documentView.frame.height - clip.bounds.maxY
        return bottomGap < 60
    }

    func scrollToBottomSoon() {
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let target = max(0, documentView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private static func markNeedsDisplayRecursively(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            markNeedsDisplayRecursively(subview)
        }
    }
}

/// Flipped so content flows top-down inside the scroll view.
private final class ChatFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Spinner + quiet label used for statusText / thinking state.
final class ChatThreadStatusRowView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true

        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = Theme.tx3
        label.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(_ text: String?) {
        if let text, !text.isEmpty {
            label.stringValue = text
            isHidden = false
            spinner.startAnimation(nil)
        } else {
            isHidden = true
            spinner.stopAnimation(nil)
        }
    }
}
