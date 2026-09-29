import AppKit

/// One pulled-in context reference: `label` renders in the chip, `token` is
/// what gets prepended to the submitted prompt text (`@file:` / `@folder:` /
/// `@diff` / a URL).
struct ChatContextReference: Equatable {
    let label: String
    let token: String
}

/// Persisted RECENT list for the ADD CONTEXT popover (real usage history —
/// starts empty).
enum ChatRecentContextStore {
    private static let key = "hermes.recentContextRefs"

    static func load() -> [ChatContextReference] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: String]] else { return [] }
        return raw.compactMap { entry in
            guard let label = entry["label"], let token = entry["token"] else { return nil }
            return ChatContextReference(label: label, token: token)
        }
    }

    static func remember(_ reference: ChatContextReference) {
        var all = load().filter { $0 != reference }
        all.insert(reference, at: 0)
        all = Array(all.prefix(5))
        UserDefaults.standard.set(all.map { ["label": $0.label, "token": $0.token] }, forKey: key)
    }
}

/// "ADD CONTEXT" popover: File… / Folder… / Git diff / Paste URL rows plus a
/// RECENT group of previously used references.
final class ChatAddContextPopoverController: NSViewController {

    enum Action {
        case file
        case folder
        case gitDiff
        case pasteURL
        case recent(ChatContextReference)
    }

    private let onAction: (Action) -> Void

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 8, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false

        let title = SectionLabelField("Add context")
        column.addArrangedSubview(title)

        let blurb = ChatWrappingLabel(
            text: "Pull local files, folders, a git diff or a URL straight into the message.",
            size: 11.5, color: Theme.tx3)
        blurb.isSelectable = false
        column.addArrangedSubview(blurb)
        blurb.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -22).isActive = true
        column.setCustomSpacing(8, after: blurb)

        addRow(to: column, symbol: "doc", title: "File…") { [onAction] in onAction(.file) }
        addRow(to: column, symbol: "folder", title: "Folder…") { [onAction] in onAction(.folder) }
        addRow(to: column, symbol: "arrow.triangle.branch", title: "Git diff") { [onAction] in onAction(.gitDiff) }
        addRow(to: column, symbol: "link", title: "Paste URL") { [onAction] in onAction(.pasteURL) }

        let recents = ChatRecentContextStore.load()
        if !recents.isEmpty {
            let rule = ChatHairlineView()
            column.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
            column.setCustomSpacing(6, after: rule)

            let recentTitle = SectionLabelField("Recent")
            column.addArrangedSubview(recentTitle)
            for reference in recents {
                addRow(to: column, symbol: nil, monoPrefix: "@",
                       title: reference.label, mono: true) { [onAction] in
                    onAction(.recent(reference))
                }
            }
        }

        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 272),
        ])
        view = container
    }

    private func addRow(to column: NSStackView, symbol: String?, monoPrefix: String? = nil,
                        title: String, mono: Bool = false, action: @escaping () -> Void) {
        let row = ChatContextMenuRow(symbol: symbol, monoPrefix: monoPrefix,
                                     title: title, mono: mono, action: action)
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
    }
}

/// Menu-like row: optional SF symbol or mono "@" prefix + title; hover fill.
private final class ChatContextMenuRow: NSControl {
    private let pickHandler: () -> Void
    private var hovering = false

    init(symbol: String?, monoPrefix: String?, title: String, mono: Bool,
         action: @escaping () -> Void) {
        self.pickHandler = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        var views: [NSView] = []
        if let symbol {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            icon.contentTintColor = Theme.tx2
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(icon)
        }
        if let monoPrefix {
            let prefix = NSTextField(labelWithString: monoPrefix)
            prefix.font = Theme.monoFont(ofSize: 11, weight: .semibold)
            prefix.textColor = Theme.tx3
            views.append(prefix)
        }
        let label = NSTextField(labelWithString: title)
        label.font = mono ? Theme.monoFont(ofSize: 12) : NSFont.systemFont(ofSize: 13)
        label.textColor = Theme.tx
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        views.append(label)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = hovering ? Theme.bgHover.cgColor : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pickHandler()
    }
}
