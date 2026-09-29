import AppKit
import Combine

/// Owns section navigation: swaps both sidebar and content view controllers,
/// tracks the last workspace section for the Dashboard-grid toggle, and
/// publishes the current section so toolbar/menus stay in sync.
@MainActor
final class SectionCoordinator: ObservableObject {
    @Published private(set) var currentSection: AppSection = .chat
    private(set) var lastWorkspaceSection: AppSection = .chat

    private weak var splitViewController: MainSplitViewController?
    private var sidebarCache: [AppSection: NSViewController] = [:]
    private var contentCache: [AppSection: NSViewController] = [:]

    /// Called once by MainWindowController; shows the initial section.
    func attach(to splitViewController: MainSplitViewController) {
        self.splitViewController = splitViewController
        show(currentSection)
    }

    /// Plain navigation (menus, gear, segmented control).
    func navigate(to section: AppSection) {
        if section.isWorkspace {
            lastWorkspaceSection = section
        }
        guard section != currentSection else { return }
        currentSection = section
        show(section)
    }

    /// Dashboard grid: on dashboard already -> back to last workspace section.
    func toggleDashboard() {
        if currentSection == .dashboard {
            navigate(to: lastWorkspaceSection)
        } else {
            navigate(to: .dashboard)
        }
    }

    private func show(_ section: AppSection) {
        guard let split = splitViewController else { return }
        split.showSidebar(sidebarViewController(for: section))
        split.showContent(contentViewController(for: section))
    }

    // MARK: - View-controller factory (cached per section)

    func sidebarViewController(for section: AppSection) -> NSViewController {
        cached(&sidebarCache, for: section) {
            switch section {
            case .chat: return ChatSidebarViewController()
            case .skills: return SkillsSidebarViewController()
            case .automations: return AutomationsSidebarViewController()
            case .dashboard: return DashboardSidebarViewController()
            case .settings: return SettingsSidebarViewController()
            }
        }
    }

    func contentViewController(for section: AppSection) -> NSViewController {
        cached(&contentCache, for: section) {
            switch section {
            case .chat: return ChatContentViewController()
            case .skills: return SkillsContentViewController()
            case .automations: return AutomationsContentViewController()
            case .dashboard: return DashboardContentViewController()
            case .settings: return SettingsContentViewController()
            }
        }
    }

    private func cached(
        _ store: inout [AppSection: NSViewController],
        for section: AppSection,
        make: () -> NSViewController
    ) -> NSViewController {
        if let cached = store[section] { return cached }
        let vc = make()
        store[section] = vc
        return vc
    }
}
