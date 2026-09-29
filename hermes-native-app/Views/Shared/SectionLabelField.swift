import AppKit

/// Uppercase 11pt bold tertiary label used for sidebar/list section headers.
final class SectionLabelField: NSTextField {
    convenience init(_ title: String) {
        self.init(labelWithString: title.uppercased())
        font = Theme.sectionLabelFont
        textColor = .tertiaryLabelColor
    }

    override var stringValue: String {
        get { super.stringValue }
        set { super.stringValue = newValue.uppercased() }
    }
}
