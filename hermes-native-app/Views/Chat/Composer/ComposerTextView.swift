import AppKit

/// Auto-growing composer editor. Placeholder "Reply to Hermes…"; Return and
/// ⌘Return submit, ⇧Return inserts a newline, ⇧⇥ cycles permission modes
/// (handled by the owning view via `NSTextViewDelegate.doCommandBy`).
final class ChatComposerTextView: NSTextView {

    var placeholder = "Reply to Hermes…"
    /// ⌘Return fallback (Return is routed through doCommandBy on the delegate).
    var onCommandReturn: (() -> Void)?

    static func make() -> ChatComposerTextView {
        let view = ChatComposerTextView(frame: .zero)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = NSFont.systemFont(ofSize: 14)
        view.textColor = Theme.tx
        view.insertionPointColor = Theme.acc
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 4
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 24)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        return view
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    /// Preferred content height for the current text (used by the composer to
    /// drive its height constraint).
    var contentHeight: CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 28 }
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + textContainerInset.height * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: Theme.tx3,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 4),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
}
