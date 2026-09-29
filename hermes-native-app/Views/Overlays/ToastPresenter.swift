//
//  ToastPresenter.swift
//  hermes-native-app
//
//  Undo toast (design spec §6): frosted pill floating bottom-center of the
//  main window's CONTENT area (offset right of the sidebar), with optional
//  accent "Undo" action and an × close button. Slides up + fades in,
//  auto-dismisses after 5 s, one toast at a time.
//

import AppKit

@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private weak var currentToast: NSView?
    private var dismissWork: DispatchWorkItem?

    private init() {}

    /// Show a toast in the main window. `undo` (with `undoTitle`, default
    /// "Undo") renders the accent pill button; omit both for plain toasts.
    func show(text: String, undoTitle: String = "Undo", undo: (() -> Void)? = nil) {
        guard let window = hostWindow(), let contentView = window.contentView else { return }

        removeCurrent(animated: false)

        let toast = ToastPillView(
            text: text,
            undoTitle: undo == nil ? nil : undoTitle,
            onUndo: { [weak self] in
                undo?()
                self?.removeCurrent(animated: true)
            },
            onClose: { [weak self] in
                self?.removeCurrent(animated: true)
            }
        )

        let size = toast.fittingSize
        let x = contentView.bounds.midX + sidebarHalfOffset(for: window) - size.width / 2
        toast.frame = NSRect(x: x, y: 10, width: size.width, height: size.height)
        toast.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        toast.alphaValue = 0
        contentView.addSubview(toast)
        currentToast = toast

        var target = toast.frame
        target.origin.y = 22
        if Motion.reduceMotion {
            toast.alphaValue = 1
            toast.frame = target
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toast.animator().alphaValue = 1
                toast.animator().frame = target
            }
        }

        let work = DispatchWorkItem { [weak self] in
            self?.removeCurrent(animated: true)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func removeCurrent(animated: Bool) {
        dismissWork?.cancel()
        dismissWork = nil
        guard let toast = currentToast else { return }
        currentToast = nil
        guard animated, !Motion.reduceMotion else {
            toast.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            toast.animator().alphaValue = 0
        }, completionHandler: {
            toast.removeFromSuperview()
        })
    }

    /// The workspace window — never a popover/panel key window.
    private func hostWindow() -> NSWindow? {
        if let delegate = NSApp.delegate as? AppDelegate,
           let window = delegate.mainWindowController?.window, window.isVisible {
            return window
        }
        return NSApp.mainWindow
    }

    /// Design floats the pill at the center of the content area
    /// (`left: calc(50% + 135px)` with the 270 pt sidebar visible).
    private func sidebarHalfOffset(for window: NSWindow) -> CGFloat {
        guard let split = window.contentViewController as? MainSplitViewController,
              let sidebarItem = split.splitViewItems.first, !sidebarItem.isCollapsed else {
            return 0
        }
        return MainSplitViewController.sidebarWidth / 2
    }
}

// MARK: - Pill view

private final class ToastPillView: NSVisualEffectView {
    init(text: String, undoTitle: String?, onUndo: @escaping () -> Void, onClose: @escaping () -> Void) {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = Theme.tx
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        var views: [NSView] = [label]
        if let undoTitle {
            views.append(ToastUndoButton(title: undoTitle, handler: onUndo))
        }
        views.append(ToastCloseButton(handler: onClose))

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = Theme.line2.cgColor
    }
}

/// Accent "Undo": accent text on an accent-soft rounded fill.
private final class ToastUndoButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: Theme.acc,
        ])
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 22
        size.height = 24
        return size
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accSoft.cgColor
    }

    @objc private func fire() { handler() }
}

/// Quiet × close button.
private final class ToastCloseButton: NSButton {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        contentTintColor = Theme.tx3
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    @objc private func fire() { handler() }
}
