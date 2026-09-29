//
//  SkillsCommonViews.swift
//  hermes-native-app
//
//  Shared building blocks for the Skills hub content pages: the scrolling
//  page scaffold (max-width 900 column, 28/36/70 padding), raised cards,
//  pills, hairlines and status dots — all Theme-driven and appearance-aware.
//

import AppKit
import Combine

/// Raised card: bgRaised fill, hairline border, radius 12 (design `.card`).
class SkillsCardView: NSView {
    init(cornerRadius: CGFloat = 12) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgRaised.cgColor
        layer?.borderColor = Theme.line.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 8pt round status dot (Theme.ok when on, Theme.tx3 when off).
final class SkillsStatusDotView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Small rounded pill with a label ("used 14×", "Connected", "Custom" tags).
final class SkillsPillView: NSView {
    private let label: NSTextField
    private var fill: NSColor
    private var stroke: NSColor?

    init(text: String,
         textColor: NSColor,
         fill: NSColor,
         stroke: NSColor? = nil,
         fontSize: CGFloat = 10.5,
         padH: CGFloat = 8,
         padV: CGFloat = 3) {
        label = NSTextField(labelWithString: text)
        self.fill = fill
        self.stroke = stroke
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = stroke == nil ? 0 : 1

        label.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = textColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pin(to: self, insets: NSEdgeInsets(top: padV, left: padH, bottom: padV, right: padH))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        if let stroke { layer?.borderColor = stroke.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Rounded monogram tile (36pt, design messaging-card glyph tile).
final class SkillsMonogramTileView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(glyph: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        label.stringValue = glyph
        label.font = Theme.monoFont(ofSize: 15, weight: .semibold)
        label.textColor = Theme.tx
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.center(in: self)
        constrainSize(NSSize(width: 36, height: 36))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.bgInset2.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Label factories / alerts

enum SkillsUI {
    /// 20pt page title.
    static func title(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        field.textColor = Theme.tx
        return field
    }

    /// 13pt secondary blurb under the title (wraps).
    static func blurb(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = Theme.tx2
        field.isSelectable = false
        return field
    }

    /// Quiet centered placeholder for empty / loading states.
    static func placeholder(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: 12.5)
        field.textColor = Theme.tx3
        field.alignment = .center
        field.isSelectable = false
        return field
    }

    static func presentError(_ message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Something went wrong"
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Page scaffold

/// Base view controller for Skills hub pages: a scroll view whose content
/// column is centered, max 828pt wide (design max-width 900 minus padding),
/// padded 28 top / 36 sides / 70 bottom.
class SkillsPageViewController: NSViewController {
    let column = NSStackView()
    let hub = SkillsHubModel.shared
    var store: HermesStore { hub.store }
    var cancellables = Set<AnyCancellable>()

    override func loadView() {
        // fullSizeContentView window: default automaticallyAdjustsContentInsets
        // keeps the content below the unified toolbar.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = docView

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(column)

        let clip = scroll.contentView

        NSLayoutConstraint.activate([
            docView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            docView.topAnchor.constraint(equalTo: clip.topAnchor),
            docView.widthAnchor.constraint(equalTo: clip.widthAnchor),

            column.topAnchor.constraint(equalTo: docView.topAnchor, constant: 28),
            column.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 36),
            column.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -36),
            docView.bottomAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: 70),
        ])

        view = scroll
    }

    /// Adds `subview` stretched to the full column width.
    func addFullWidth(_ subview: NSView, spacingAfter: CGFloat? = nil) {
        column.addArrangedSubview(subview)
        subview.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        if let spacingAfter {
            column.setCustomSpacing(spacingAfter, after: subview)
        }
    }
}
