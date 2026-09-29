import AppKit

// MARK: - Auto Layout

extension NSView {
    /// Pins this view to the four edges of `other` (positive insets shrink
    /// inward on every edge). Disables autoresizing translation.
    @discardableResult
    func pin(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) -> [NSLayoutConstraint] {
        translatesAutoresizingMaskIntoConstraints = false
        let cs = [
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            other.bottomAnchor.constraint(equalTo: bottomAnchor, constant: insets.bottom),
            other.trailingAnchor.constraint(equalTo: trailingAnchor, constant: insets.right),
        ]
        NSLayoutConstraint.activate(cs)
        return cs
    }

    /// Centers this view within `other`.
    @discardableResult
    func center(in other: NSView) -> [NSLayoutConstraint] {
        translatesAutoresizingMaskIntoConstraints = false
        let cs = [
            centerXAnchor.constraint(equalTo: other.centerXAnchor),
            centerYAnchor.constraint(equalTo: other.centerYAnchor),
        ]
        NSLayoutConstraint.activate(cs)
        return cs
    }

    /// Constrains this view to a fixed size.
    @discardableResult
    func constrainSize(_ size: NSSize) -> [NSLayoutConstraint] {
        translatesAutoresizingMaskIntoConstraints = false
        let cs = [
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ]
        NSLayoutConstraint.activate(cs)
        return cs
    }
}

// MARK: - Labels

extension NSTextField {
    /// A non-editable, Theme-styled label. `wrapping` makes it a wrapping label.
    static func label(_ text: String = "",
                      size: CGFloat = 13,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = Theme.tx,
                      wrapping: Bool = false) -> NSTextField {
        let field = wrapping
            ? NSTextField(wrappingLabelWithString: text)
            : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        if wrapping { field.isSelectable = false }
        return field
    }
}
