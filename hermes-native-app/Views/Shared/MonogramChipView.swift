import AppKit

/// Rounded 18pt square with a single monochrome monogram letter — platform
/// identity per the design (never brand colors).
final class MonogramChipView: NSView {
    var letter: String {
        didSet { label.stringValue = String(letter.prefix(1)) }
    }

    private let label = NSTextField(labelWithString: "")

    init(letter: String) {
        self.letter = letter
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        layer?.cornerRadius = 5

        label.stringValue = String(letter.prefix(1))
        label.font = Theme.monoFont(ofSize: 10, weight: .semibold)
        label.textColor = Theme.tx2
        label.alignment = .center
        addSubview(label)
        label.center(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bgInset2.cgColor
    }
}
