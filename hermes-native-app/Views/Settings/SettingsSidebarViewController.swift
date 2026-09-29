import AppKit
import Combine

/// Settings sidebar: "Settings" title then five category rows with small glyph
/// tiles (Agent / Compute / Providers / Appearance / About); selection is a
/// solid-accent row. No workspace footer here (per design).
final class SettingsSidebarViewController: NSViewController {

    private var rows: [SettingsCategoryRow] = []
    private var cancellables = Set<AnyCancellable>()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = NSTextField.label("Settings", size: 13, weight: .semibold, color: Theme.tx)
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        for category in SettingsCategory.allCases {
            let row = SettingsCategoryRow(category: category)
            row.onSelect = { SettingsSelectionState.shared.selection.send(category) }
            rows.append(row)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            // Pin below the titlebar/traffic-lights (safe area), matching the
            // Chat/Skills sidebars — view.topAnchor would tuck under the lights.
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])

        SettingsSelectionState.shared.selection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] selected in
                self?.rows.forEach { $0.isSelectedRow = ($0.category == selected) }
            }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.rows.forEach { $0.refreshColors() }
        }
    }
}

/// Whole-row-clickable category row: 22pt glyph tile + label.
/// Selected = solid accent background, white label, translucent white tile.
final class SettingsCategoryRow: NSControl {

    let category: SettingsCategory
    var onSelect: (() -> Void)?

    var isSelectedRow = false {
        didSet { refreshColors() }
    }

    private let tile = NSView()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    init(category: SettingsCategory) {
        self.category = category
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.constrainSize(NSSize(width: 22, height: 22))

        glyphLabel.stringValue = category.glyph
        glyphLabel.font = NSFont.systemFont(ofSize: 12)
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyphLabel)
        glyphLabel.center(in: tile)

        titleLabel.stringValue = category.title
        titleLabel.font = Theme.bodyFont

        let row = NSStackView(views: [tile, titleLabel, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pin(to: self)

        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func refreshColors() {
        let rowBackground: NSColor = isSelectedRow ? Theme.acc : .clear
        let tileBackground: NSColor = isSelectedRow
            ? NSColor.white.withAlphaComponent(0.22)
            : Theme.bgInset2
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.layer?.backgroundColor = rowBackground.cgColor
            self?.tile.layer?.backgroundColor = tileBackground.cgColor
        }
        titleLabel.textColor = isSelectedRow ? .white : Theme.tx
        glyphLabel.textColor = isSelectedRow ? .white : Theme.tx2
    }
}
