import AppKit

/// Icon-only Overview toggle used by the unified AppKit toolbar.
///
/// The handoff treats Dashboard as a quiet utility button rather than a fourth
/// segment: its selected state is an accent-tinted glyph on a soft accent wash.
@MainActor
final class DashboardToggleButton: NSButton {
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            refreshTint()
        }
    }

    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "square.grid.2x2",
                        accessibilityDescription: "Dashboard")
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        toolTip = "Toggle Overview"
        wantsLayer = true
        layer?.cornerRadius = 7
        setAccessibilityLabel("Dashboard")
        setAccessibilityHelp("Toggle Overview")
        refreshTint()
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 24) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshTint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }

    override func updateLayer() {
        super.updateLayer()
        applyCurrentBackground()
    }

    func refreshTint() {
        contentTintColor = isOn ? Theme.acc : Theme.tx2
        applyCurrentBackground()
    }

    private func applyCurrentBackground() {
        let fill: NSColor = isOn ? Theme.accSoft : (isHovering ? Theme.bgHover : .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            self?.layer?.backgroundColor = fill.cgColor
        }
    }
}
