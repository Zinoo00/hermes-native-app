import AppKit

/// Phase A stand-in pane: centered secondary label naming the section slot.
/// Section view controllers subclass this until their real UI lands.
class PlaceholderViewController: NSViewController {
    private let displayName: String

    init(name: String) {
        displayName = name
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = NSView()
        let label = NSTextField(labelWithString: "\(displayName) — pending")
        label.font = Theme.bodyFont
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        view.addSubview(label)
        label.center(in: view)
        self.view = view
    }
}
