import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SectionCoordinator()
    private(set) var mainWindowController: MainWindowController?
    private lazy var updateSheet = UpdateSheetController()
    private lazy var commandBar = CommandBarController(
        store: AppEnvironment.shared.store,
        coordinator: coordinator
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        Theme.shared.applyAppearance()
        NSApp.mainMenu = MainMenuBuilder.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController(coordinator: coordinator)
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate()

        // Frontend-first: DEBUG builds run on MockData (no Python backend) so the
        // UI is fully populated for design work. Set HERMES_REAL=1 to use the real
        // backend in Debug; Release always uses it.
        #if DEBUG
        if ProcessInfo.processInfo.environment["HERMES_REAL"] == "1" {
            Task { await AppEnvironment.shared.store.start() }
        } else {
            AppEnvironment.shared.store.startMock()
        }
        #else
        Task { await AppEnvironment.shared.store.start() }
        #endif

        DebugSnapshot.runIfRequested(coordinator: coordinator, window: controller.window)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never .terminateLater + async cleanup: the nested event loop inside
        // -[NSApplication _shouldTerminate] does not drain main-actor tasks,
        // so the reply never fires and Quit hangs (verified with `sample`).
        // The backend child is reaped synchronously in applicationWillTerminate.
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendSupervisor.emergencySyncStop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The app will supervise the local hermes backend; stay alive.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    // MARK: - Menu / toolbar actions (nil-target, resolved via responder chain)

    @objc func showSettings(_ sender: Any?) {
        coordinator.navigate(to: .settings)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        guard let window = mainWindowController?.window else { return }
        updateSheet.present(on: window)
    }

    @objc func newConversation(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        coordinator.navigate(to: .chat)
        Task { await AppEnvironment.shared.store.newSession() }
    }

    @objc func goToOverview(_ sender: Any?) {
        coordinator.navigate(to: .dashboard)
    }

    @objc func goToChat(_ sender: Any?) {
        coordinator.navigate(to: .chat)
    }

    @objc func goToSkills(_ sender: Any?) {
        coordinator.navigate(to: .skills)
    }

    @objc func goToAutomations(_ sender: Any?) {
        coordinator.navigate(to: .automations)
    }

    @objc func showNeedsAttention(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        mainWindowController?.showAttentionPopover()
    }

    @objc func setAppearance(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let mode = AppearanceMode(rawValue: raw) else { return }
        Theme.shared.appearanceMode = mode
    }
}

extension AppDelegate: CommandBarActions {
    /// View ▸ Toggle Command Bar (⌘K).
    func toggleCommandBar(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        commandBar.toggle(over: mainWindowController?.window)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setAppearance(_:)),
           let raw = menuItem.representedObject as? String,
           let mode = AppearanceMode(rawValue: raw) {
            menuItem.state = Theme.shared.appearanceMode == mode ? .on : .off
        }
        return true
    }
}
