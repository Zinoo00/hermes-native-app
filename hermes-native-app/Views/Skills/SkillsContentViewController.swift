//
//  SkillsContentViewController.swift
//  hermes-native-app
//
//  Container for the seven Skills-hub tabs. Swaps the child view controller
//  when SkillsHubModel.tab changes (driven by the source-list sidebar).
//

import AppKit
import Combine

final class SkillsContentViewController: NSViewController {
    private let hub = SkillsHubModel.shared
    private var cancellables = Set<AnyCancellable>()
    private var cache: [SkillsTab: NSViewController] = [:]
    private var current: NSViewController?

    override func loadView() {
        view = SkillsContentBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hub.$tab
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in self?.show(tab) }
            .store(in: &cancellables)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        hub.refreshAll()
    }

    private func show(_ tab: SkillsTab) {
        let next = viewController(for: tab)
        guard next !== current else { return }
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        view.addSubview(next.view)
        current = next
    }

    private func viewController(for tab: SkillsTab) -> NSViewController {
        if let cached = cache[tab] { return cached }
        let controller: NSViewController
        switch tab {
        case .personality: controller = SkillsPersonalityViewController()
        case .context: controller = SkillsContextViewController()
        case .memory: controller = SkillsMemoryViewController()
        case .skills: controller = SkillsGridViewController()
        case .commands: controller = SkillsCommandsViewController()
        case .messaging: controller = SkillsMessagingViewController()
        case .tools: controller = SkillsToolsViewController()
        }
        cache[tab] = controller
        return controller
    }
}

/// Content-area background (Theme.bg), appearance-adaptive.
private final class SkillsContentBackgroundView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.bg.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
