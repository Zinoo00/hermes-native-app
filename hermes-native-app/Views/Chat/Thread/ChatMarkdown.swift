import AppKit

/// Minimal markdown -> NSAttributedString renderer for assistant turns.
/// Parses with Foundation's `AttributedString(markdown:)` using `.full`
/// interpretation and maps presentation intents (headers, lists, code blocks,
/// quotes, emphasis, links) to fonts/colors; falls back to plain styled text
/// when parsing fails.
enum ChatMarkdown {

    static func render(_ text: String, baseSize: CGFloat = 13.5) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return plain(text, size: baseSize)
        }

        let output = NSMutableAttributedString()
        var previousBlockID: [Int]?

        for run in parsed.runs {
            let runText = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let blockID = components.map(\.identity)

            var headerLevel = 0
            var isCodeBlock = false
            var isQuote = false
            var isListItem = false
            var isOrderedList = false
            var listOrdinal = 1
            var isThematicBreak = false
            for component in components {
                switch component.kind {
                case .header(let level): headerLevel = level
                case .codeBlock: isCodeBlock = true
                case .blockQuote: isQuote = true
                case .listItem(let ordinal):
                    isListItem = true
                    listOrdinal = ordinal
                case .orderedList: isOrderedList = true
                case .thematicBreak: isThematicBreak = true
                default: break
                }
            }

            if blockID != previousBlockID {
                if previousBlockID != nil {
                    output.append(NSAttributedString(string: "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: baseSize),
                    ]))
                }
                if isListItem {
                    let prefix = isOrderedList ? "\(listOrdinal). " : "•  "
                    output.append(NSAttributedString(string: prefix, attributes: [
                        .font: NSFont.systemFont(ofSize: baseSize, weight: isOrderedList ? .regular : .semibold),
                        .foregroundColor: Theme.tx2,
                    ]))
                }
                previousBlockID = blockID
            }

            if isThematicBreak { continue }

            var bold = headerLevel > 0
            var italic = false
            var mono = isCodeBlock
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { bold = true }
                if inline.contains(.emphasized) { italic = true }
                if inline.contains(.code) { mono = true }
            }

            var size = baseSize
            if headerLevel > 0 {
                size = baseSize + CGFloat(max(0, 4 - min(headerLevel, 4))) * 1.5
            }

            var font: NSFont = mono
                ? Theme.monoFont(ofSize: max(10, size - 1.5))
                : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            if italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isQuote ? Theme.tx2 : Theme.tx,
            ]
            if mono, !isCodeBlock {
                attrs[.backgroundColor] = Theme.bgInset
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = Theme.acc
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: runText, attributes: attrs))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 7
        output.addAttribute(.paragraphStyle, value: paragraph,
                            range: NSRange(location: 0, length: output.length))
        return output
    }

    /// Plain styled text (streaming appends and parser fallback).
    static func plain(_ text: String, size: CGFloat = 13.5) -> NSAttributedString {
        NSAttributedString(string: text, attributes: plainAttributes(size: size))
    }

    static func plainAttributes(size: CGFloat = 13.5) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 7
        return [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: Theme.tx,
            .paragraphStyle: paragraph,
        ]
    }
}
