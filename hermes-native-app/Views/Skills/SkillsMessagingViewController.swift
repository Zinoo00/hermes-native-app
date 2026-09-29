//
//  SkillsMessagingViewController.swift
//  hermes-native-app
//
//  MESSAGING tab: 2-column platform cards from GET /api/messaging/platforms
//  (+ gateway state from /api/status). Connected platforms show a green
//  "Connected" pill; others show a bezel "Connect" button that opens the
//  platform's setup docs (partial: no in-app connect flow yet). A CLI / TUI
//  "Always on" card represents this app's own gateway connection.
//

import AppKit
import Combine

final class SkillsMessagingViewController: SkillsPageViewController {

    private let grid = NSStackView()
    private let statusField = SkillsUI.placeholder("Loading platforms…")

    override func viewDidLoad() {
        super.viewDidLoad()

        addFullWidth(SkillsUI.title("Messaging"), spacingAfter: 5)
        addFullWidth(
            SkillsUI.blurb("Talk to Hermes from anywhere — one gateway process bridges every channel."),
            spacingAfter: 22
        )

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        addFullWidth(grid)

        addFullWidth(statusField)

        hub.$messagingCards
            .combineLatest(hub.$messagingLoaded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cards, loaded in
                self?.render(cards: cards, loaded: loaded)
            }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        Task {
            await store.refreshStatus()
            await hub.refreshMessaging()
        }
    }

    private func render(cards: [SkillsMessagingCard], loaded: Bool) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonHolders.removeAll()

        guard !cards.isEmpty else {
            statusField.isHidden = false
            statusField.stringValue = loaded
                ? "The backend reported no messaging platforms."
                : "Loading platforms…"
            return
        }
        statusField.isHidden = true

        var index = 0
        while index < cards.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false
            for column in 0..<2 {
                if index + column < cards.count {
                    row.addArrangedSubview(makeCard(cards[index + column]))
                } else {
                    row.addArrangedSubview(NSView())
                }
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            index += 2
        }
    }

    private func makeCard(_ card: SkillsMessagingCard) -> NSView {
        let container = SkillsCardView()

        let tile = SkillsMonogramTileView(glyph: card.glyph)

        let name = NSTextField(labelWithString: card.name)
        name.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        name.textColor = Theme.tx
        name.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: card.detail)
        detail.font = NSFont.systemFont(ofSize: 11.5)
        detail.textColor = Theme.tx3
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [name, detail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let trailing: NSView
        if card.connected {
            trailing = SkillsPillView(
                text: "Connected",
                textColor: Theme.ok,
                fill: Theme.ok.withAlphaComponent(0.14),
                fontSize: 11,
                padH: 9,
                padV: 3
            )
        } else {
            let button = NSButton(title: "Connect", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11.5)
            let holder = SkillsButtonActionHolder { [weak self] in
                self?.openDocs(for: card)
            }
            button.target = holder
            button.action = #selector(SkillsButtonActionHolder.buttonClicked)
            buttonHolders.append(holder)
            button.toolTip = "Opens the \(card.name) setup guide — credentials are configured on the backend."
            trailing = button
        }
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [tile, textStack, NSView(), trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        row.pin(to: container, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))

        if card.alwaysOn {
            container.toolTip = "This app is a live gateway client — the CLI / TUI channel is always available."
        }
        return container
    }

    private var buttonHolders: [SkillsButtonActionHolder] = []

    private func openDocs(for card: SkillsMessagingCard) {
        let fallback = URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/messaging/")
        guard let url = card.docsURL ?? fallback else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Tiny target box so each NSButton can carry its own closure.
final class SkillsButtonActionHolder: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func buttonClicked() {
        handler()
    }
}
