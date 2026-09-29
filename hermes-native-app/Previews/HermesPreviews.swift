#if DEBUG
import AppKit
import SwiftUI

//  HermesPreviews.swift
//
//  Xcode canvas previews for the AppKit UI. Open this file (or any file with a
//  #Preview block) and show the canvas (⌥⌘↩) to render live.
//
//  Why previews matter here: the app uses the macOS 26 "liquid glass" sidebar
//  and scroll-edge materials. Those are composited by the WindowServer, so
//  offscreen bitmap snapshots (cacheDisplay) render them blank — but the Xcode
//  preview canvas hosts the controller in a real window, so glass, vibrancy and
//  concentric-glass insets all render correctly. This is the ground-truth way
//  to see the UI without launching the full app.
//
//  Everything here is DEBUG-only and seeds AppEnvironment.shared.store with
//  sample data (no backend is spawned).

@MainActor
private enum PreviewFactory {
    /// Seed the shared store once so data-driven views populate.
    static func seed() {
        AppEnvironment.shared.store.seedPreviewData()
    }

    /// Full app shell (glass sidebar + content) focused on `section`.
    static func shell(_ section: AppSection, size: NSSize = NSSize(width: 1200, height: 800)) -> NSViewController {
        seed()
        let split = MainSplitViewController()
        let coordinator = SectionCoordinator()
        coordinator.attach(to: split)
        coordinator.navigate(to: section)
        split.preferredContentSize = size
        return split
    }

    /// A single content pane, sized like the content half of the window.
    static func content(_ vc: NSViewController, size: NSSize = NSSize(width: 900, height: 760)) -> NSViewController {
        seed()
        vc.preferredContentSize = size
        return vc
    }

    /// A single sidebar pane at its real 270 pt width.
    static func sidebar(_ vc: NSViewController) -> NSViewController {
        seed()
        vc.preferredContentSize = NSSize(width: MainSplitViewController.sidebarWidth, height: 760)
        return vc
    }
}

// MARK: - Full shells (glass sidebar + content, per section)

#Preview("Shell · Chat") { PreviewFactory.shell(.chat) }
#Preview("Shell · Dashboard") { PreviewFactory.shell(.dashboard) }
#Preview("Shell · Skills") { PreviewFactory.shell(.skills) }
#Preview("Shell · Automations") { PreviewFactory.shell(.automations) }
#Preview("Shell · Settings") { PreviewFactory.shell(.settings) }

// MARK: - Content panes (focused, no sidebar)

#Preview("Content · Chat (empty)") { PreviewFactory.content(ChatContentViewController()) }
#Preview("Content · Dashboard") { PreviewFactory.content(DashboardContentViewController()) }
#Preview("Content · Skills") { PreviewFactory.content(SkillsContentViewController()) }
#Preview("Content · Automations") { PreviewFactory.content(AutomationsContentViewController()) }
#Preview("Content · Settings") { PreviewFactory.content(SettingsContentViewController()) }

// MARK: - Sidebars (270 pt, on their own)

#Preview("Sidebar · Chat") { PreviewFactory.sidebar(ChatSidebarViewController()) }
#Preview("Sidebar · Dashboard") { PreviewFactory.sidebar(DashboardSidebarViewController()) }
#Preview("Sidebar · Skills") { PreviewFactory.sidebar(SkillsSidebarViewController()) }
#Preview("Sidebar · Automations") { PreviewFactory.sidebar(AutomationsSidebarViewController()) }
#Preview("Sidebar · Settings") { PreviewFactory.sidebar(SettingsSidebarViewController()) }

#endif
