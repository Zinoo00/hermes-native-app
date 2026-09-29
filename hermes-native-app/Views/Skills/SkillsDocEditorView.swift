//
//  SkillsDocEditorView.swift
//  hermes-native-app
//
//  Shared markdown document card (SOUL.md / AGENTS.md): header row with mono
//  filename + sync meta + Edit/Done bezel button; READ mode renders markdown
//  in the design's typographic style (H1 bold, H2 uppercase eyebrow, accent
//  bullets); EDIT mode is a mono NSTextView over the raw markdown. Files are
//  read/written through the backend fs API (GET /api/fs/read-text,
//  POST /api/fs/write-text) so edits apply to Hermes everywhere.
//

import AppKit
import Combine

final class SkillsDocEditorView: SkillsCardView, NSTextViewDelegate {

    enum DocState {
        case idle           // waiting for a path (backend not up yet)
        case loading
        case loaded
        case missing        // file doesn't exist -> offer "Create …"
        case failed(String)
    }

    // MARK: Configuration

    /// Meta caption prefix when synced ("Personality · synced").
    var metaPrefix = "Document"
    /// Shown in the missing state above the create button.
    var missingMessage = "This file doesn't exist yet."
    /// Title of the create button; nil hides the create affordance.
    var createTitle: String?
    /// Content written by the create button.
    var createContent = ""
    /// Fires whenever the (unsaved) text changes — presets/custom detection.
    var onTextChanged: ((String) -> Void)?

    // MARK: State

    private(set) var state: DocState = .idle
    private(set) var path: String?
    private(set) var savedText = ""
    private(set) var currentText = ""
    private(set) var isEditingDoc = false
    var isModified: Bool { currentText != savedText }

    private var loadGeneration = 0

    // MARK: Subviews

    private let nameField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Edit", target: nil, action: nil)
    private let errorField = NSTextField(wrappingLabelWithString: "")

    private let bodyStack = NSStackView()
    private let errorBox = NSView()
    private let readStack = NSStackView()
    private let statusField = SkillsUI.placeholder("")
    private let missingStack = NSStackView()
    private let missingLabel = SkillsUI.placeholder("")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private var editorScroll: NSScrollView!
    private var textView: NSTextView!
    private var readBoxView: NSView!
    private var statusBoxView: NSView!
    private var missingBoxView: NSView!

    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init() {
        super.init(cornerRadius: 12)
        buildUI()
        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            guard let self, case .loaded = self.state, !self.isEditingDoc else { return }
            self.renderReadBlocks() // bullets re-tint with the accent
        }
    }

    private func buildUI() {
        // — Header bar
        let header = SkillsDocHeaderBarView()

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = Theme.tx2

        nameField.font = Theme.monoFont(ofSize: 12, weight: .semibold)
        nameField.textColor = Theme.tx
        metaField.font = NSFont.systemFont(ofSize: 11.5)
        metaField.textColor = Theme.tx3
        metaField.lineBreakMode = .byTruncatingTail

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        actionButton.target = self
        actionButton.action = #selector(actionButtonClicked)

        let headerRow = NSStackView(views: [icon, nameField, metaField, NSView(), actionButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 9
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)
        headerRow.pin(to: header, insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))

        // — Body: read stack / editor / status / missing, swapped by hiding
        //   arranged subviews (NSStackView detaches hidden views from layout).
        readStack.orientation = .vertical
        readStack.alignment = .leading
        readStack.spacing = 0
        let readBox = Self.paddedBox(readStack, top: 18, side: 22, bottom: 22)

        buildEditor()

        missingLabel.alignment = .center
        createButton.bezelStyle = .rounded
        createButton.target = self
        createButton.action = #selector(createClicked)
        missingStack.orientation = .vertical
        missingStack.alignment = .centerX
        missingStack.spacing = 12
        missingStack.addArrangedSubview(missingLabel)
        missingStack.addArrangedSubview(createButton)
        let missingBox = Self.paddedBox(missingStack, top: 30, side: 22, bottom: 30, centered: true)

        let statusBox = Self.paddedBox(statusField, top: 30, side: 22, bottom: 30, centered: true)

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 0
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        for sub in [readBox, editorScroll!, statusBox, missingBox] {
            bodyStack.addArrangedSubview(sub)
            sub.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }
        editorScroll.heightAnchor.constraint(equalToConstant: 380).isActive = true
        readBoxView = readBox
        statusBoxView = statusBox
        missingBoxView = missingBox

        errorField.font = NSFont.systemFont(ofSize: 11.5)
        errorField.textColor = Theme.danger
        errorField.isSelectable = false
        errorField.isHidden = true
        errorField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorBox.isHidden = true
        errorBox.translatesAutoresizingMaskIntoConstraints = false
        errorField.translatesAutoresizingMaskIntoConstraints = false
        errorBox.addSubview(errorField)
        errorField.pin(to: errorBox, insets: NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14))

        let outer = NSStackView(views: [header, HairlineView(), bodyStack, errorBox])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        outer.pin(to: self)
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: outer.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            errorBox.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])

        // Rounded corners must clip the square-cornered header strip.
        layer?.masksToBounds = true

        render()
    }

    private func buildEditor() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 380)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Theme.monoFont(ofSize: 12.5)
        tv.textColor = Theme.tx
        tv.insertionPointColor = Theme.tx
        tv.textContainerInset = NSSize(width: 18, height: 16)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.delegate = self

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        tv.defaultParagraphStyle = paragraph
        tv.typingAttributes = [
            .font: Theme.monoFont(ofSize: 12.5),
            .foregroundColor: Theme.tx,
            .paragraphStyle: paragraph,
        ]

        scroll.documentView = tv
        editorScroll = scroll
        textView = tv
    }

    // MARK: Public API

    /// Point the card at a backend file and load it.
    func present(path: String, filename: String) {
        self.path = path
        nameField.stringValue = filename
        isEditingDoc = false
        state = .loading
        render()
        loadGeneration += 1
        let generation = loadGeneration
        Task { await self.load(generation: generation) }
    }

    /// Show the idle "waiting for backend" hint (no path resolved yet).
    func presentWaiting(filename: String) {
        nameField.stringValue = filename
        state = .idle
        render()
    }

    /// Rewrite the (unsaved) document content — used by personality presets.
    func replaceText(_ text: String) {
        guard case .loaded = state else { return }
        currentText = text
        if isEditingDoc {
            textView.string = text
        }
        render()
        onTextChanged?(currentText)
    }

    // MARK: Loading / saving

    private func load(generation: Int) async {
        guard let rest = AppEnvironment.shared.store.rest, let path else {
            if generation == loadGeneration {
                state = .idle
                render()
            }
            return
        }
        do {
            let file = try await rest.readTextFile(path: path)
            guard generation == loadGeneration else { return }
            savedText = file.text
            currentText = file.text
            state = .loaded
            render()
            onTextChanged?(currentText)
        } catch RestError.http(let status, _) where status == 404 || status == 400 {
            guard generation == loadGeneration else { return }
            state = .missing
            render()
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(error.localizedDescription)
            render()
        }
    }

    @objc private func actionButtonClicked() {
        guard case .loaded = state else { return }
        if isEditingDoc || isModified {
            save()
        } else {
            isEditingDoc = true
            render()
            window?.makeFirstResponder(textView)
        }
    }

    private func save() {
        guard let rest = AppEnvironment.shared.store.rest, let path else {
            showError("Backend not connected — changes were not saved.")
            return
        }
        if isEditingDoc { currentText = textView.string }
        let text = currentText
        actionButton.isEnabled = false
        Task {
            do {
                try await rest.writeTextFile(path: path, content: text)
                self.savedText = text
                self.isEditingDoc = false
                self.clearError()
                self.actionButton.isEnabled = true
                self.render()
                self.onTextChanged?(self.currentText)
            } catch {
                self.actionButton.isEnabled = true
                self.showError("Could not save: \(error.localizedDescription)")
            }
        }
    }

    @objc private func createClicked() {
        guard let rest = AppEnvironment.shared.store.rest, let path else {
            showError("Backend not connected.")
            return
        }
        let content = createContent
        createButton.isEnabled = false
        Task {
            do {
                try await rest.writeTextFile(path: path, content: content)
                self.createButton.isEnabled = true
                self.savedText = content
                self.currentText = content
                self.isEditingDoc = false
                self.state = .loaded
                self.clearError()
                self.render()
                self.onTextChanged?(self.currentText)
            } catch {
                self.createButton.isEnabled = true
                self.showError("Could not create file: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        errorField.stringValue = message
        errorField.isHidden = false
        errorBox.isHidden = false
    }

    private func clearError() {
        errorField.isHidden = true
        errorBox.isHidden = true
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        currentText = textView.string
        updateHeader()
        onTextChanged?(currentText)
    }

    // MARK: Rendering

    private func render() {
        updateHeader()

        readBoxView.isHidden = true
        editorScroll.isHidden = true
        statusBoxView.isHidden = true
        missingBoxView.isHidden = true

        switch state {
        case .idle:
            statusBoxView.isHidden = false
            statusField.stringValue = "Waiting for the Hermes backend…"
        case .loading:
            statusBoxView.isHidden = false
            statusField.stringValue = "Loading…"
        case .failed(let message):
            statusBoxView.isHidden = false
            statusField.stringValue = message
        case .missing:
            missingBoxView.isHidden = false
            missingLabel.stringValue = missingMessage
            if let createTitle {
                createButton.title = createTitle
                createButton.isHidden = false
            } else {
                createButton.isHidden = true
            }
        case .loaded:
            if isEditingDoc {
                editorScroll.isHidden = false
                if textView.string != currentText {
                    textView.string = currentText
                }
            } else {
                readBoxView.isHidden = false
                renderReadBlocks()
            }
        }
    }

    /// Wraps `content` in a padded box (optionally horizontally centered).
    private static func paddedBox(
        _ content: NSView,
        top: CGFloat,
        side: CGFloat,
        bottom: CGFloat,
        centered: Bool = false
    ) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        var constraints = [
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -bottom),
        ]
        if centered {
            constraints += [
                content.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                content.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: side),
                content.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -side),
            ]
        } else {
            constraints += [
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: side),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -side),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return box
    }

    private func updateHeader() {
        switch state {
        case .loaded:
            actionButton.isHidden = false
            metaField.stringValue = isModified ? "Edited · not yet saved" : "\(metaPrefix) · synced"
            let title = isEditingDoc ? "Done" : (isModified ? "Save" : "Edit")
            if isEditingDoc || isModified {
                actionButton.bezelColor = Theme.acc
                actionButton.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: NSColor.white,
                    ]
                )
            } else {
                actionButton.bezelColor = nil
                actionButton.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: Theme.tx,
                    ]
                )
            }
        case .missing:
            actionButton.isHidden = true
            metaField.stringValue = "Not created yet"
        case .idle, .loading:
            actionButton.isHidden = true
            metaField.stringValue = ""
        case .failed:
            actionButton.isHidden = true
            metaField.stringValue = "Couldn't load"
        }
    }

    /// Line-based markdown renderer matching the design's read mode:
    /// H1 17pt bold · H2 uppercase 11pt eyebrow · accent-dot bullets ·
    /// 13.5pt paragraphs; inline **bold** / `code` via AttributedString.
    private func renderReadBlocks() {
        readStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var lastView: NSView?
        func append(_ view: NSView, spacingAfter: CGFloat) {
            readStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: readStack.widthAnchor).isActive = true
            readStack.setCustomSpacing(spacingAfter, after: view)
            lastView = view
        }

        for rawLine in currentText.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let lastView {
                    readStack.setCustomSpacing(
                        readStack.customSpacing(after: lastView) + 3, after: lastView
                    )
                }
                continue
            }
            if line.hasPrefix("## ") {
                let field = NSTextField.label(
                    String(line.dropFirst(3)).uppercased(), size: 11, weight: .bold, color: Theme.tx3
                )
                if let lastView {
                    readStack.setCustomSpacing(17, after: lastView)
                }
                append(field, spacingAfter: 8)
            } else if line.hasPrefix("# ") {
                let field = NSTextField.label(String(line.dropFirst(2)), size: 17, weight: .bold)
                append(field, spacingAfter: 5)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let dot = NSTextField(labelWithString: "•")
                dot.font = NSFont.systemFont(ofSize: 13.5)
                dot.textColor = Theme.acc
                dot.setContentHuggingPriority(.required, for: .horizontal)
                let text = NSTextField(wrappingLabelWithString: "")
                text.attributedStringValue = Self.inlineMarkdown(
                    String(line.dropFirst(2)),
                    font: NSFont.systemFont(ofSize: 13.5),
                    color: Theme.tx
                )
                text.isSelectable = false
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [dot, text])
                row.orientation = .horizontal
                row.alignment = .firstBaseline
                row.spacing = 10
                append(row, spacingAfter: 6)
            } else {
                let field = NSTextField(wrappingLabelWithString: "")
                field.attributedStringValue = Self.inlineMarkdown(
                    line,
                    font: NSFont.systemFont(ofSize: 13.5),
                    color: Theme.tx2
                )
                field.isSelectable = false
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                append(field, spacingAfter: 7)
            }
        }

        if readStack.arrangedSubviews.isEmpty {
            let field = SkillsUI.placeholder("This file is empty.")
            append(field, spacingAfter: 0)
        }
    }

    /// Inline markdown (**bold**, *italic*, `code`) -> NSAttributedString.
    static func inlineMarkdown(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25

        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let fragment = String(parsed[run.range].characters)
            var runFont = font
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    runFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                }
                if intent.contains(.emphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.code) {
                    runFont = Theme.monoFont(ofSize: font.pointSize - 1)
                    attrs[.backgroundColor] = Theme.bgInset2
                }
            }
            attrs[.font] = runFont
            result.append(NSAttributedString(string: fragment, attributes: attrs))
        }
        return result
    }
}

/// Doc-card header strip: inset background + hairline handled by the stack.
private final class SkillsDocHeaderBarView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.bgInset.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
