import AppKit

/// Conversation actions travel the responder chain to the active chat content
/// controller, which keeps the menu state aligned with the focused session.
@objc protocol ConversationMenuActions {
    func sendConversationMessage(_ sender: Any?)
    func interruptConversation(_ sender: Any?)
    func branchConversation(_ sender: Any?)
    func renameConversation(_ sender: Any?)
    func archiveConversation(_ sender: Any?)
}

/// Command-bar toggle adopted by the application-level palette owner.
@objc protocol CommandBarActions {
    func toggleCommandBar(_ sender: Any?)
}

@MainActor
enum MainMenuBuilder {
    /// Builds the full main menu and wires NSApp's windowsMenu/helpMenu.
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu: appMenu(), title: "Hermes")
        mainMenu.addItem(submenu: fileMenu(), title: "File")
        mainMenu.addItem(submenu: editMenu(), title: "Edit")
        mainMenu.addItem(submenu: viewMenu(), title: "View")
        mainMenu.addItem(submenu: conversationMenu(), title: "Conversation")

        let windowMenu = self.windowMenu()
        mainMenu.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        let helpMenu = self.helpMenu()
        mainMenu.addItem(submenu: helpMenu, title: "Help")
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Hermes")
        menu.addItem(withTitle: "About Hermes",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…",
                     action: #selector(AppDelegate.showSettings(_:)),
                     keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…",
                     action: #selector(AppDelegate.checkForUpdates(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Hermes",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hermes",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Conversation",
                     action: #selector(AppDelegate.newConversation(_:)),
                     keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Overview",
                     action: #selector(AppDelegate.goToOverview(_:)),
                     keyEquivalent: "0")
        menu.addItem(withTitle: "Chat",
                     action: #selector(AppDelegate.goToChat(_:)),
                     keyEquivalent: "1")
        menu.addItem(withTitle: "Skills",
                     action: #selector(AppDelegate.goToSkills(_:)),
                     keyEquivalent: "2")
        menu.addItem(withTitle: "Automations",
                     action: #selector(AppDelegate.goToAutomations(_:)),
                     keyEquivalent: "3")
        menu.addItem(withTitle: "Needs Attention",
                     action: #selector(AppDelegate.showNeedsAttention(_:)),
                     keyEquivalent: "9")
        menu.addItem(.separator())
        let toggleSidebar = menu.addItem(withTitle: "Toggle Sidebar",
                                         action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                         keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(withTitle: "Toggle Command Bar",
                     action: #selector(CommandBarActions.toggleCommandBar(_:)),
                     keyEquivalent: "k")
        menu.addItem(.separator())
        let light = menu.addItem(withTitle: "Appearance: Light",
                                 action: #selector(AppDelegate.setAppearance(_:)),
                                 keyEquivalent: "")
        light.representedObject = AppearanceMode.light.rawValue
        let dark = menu.addItem(withTitle: "Appearance: Dark",
                                action: #selector(AppDelegate.setAppearance(_:)),
                                keyEquivalent: "")
        dark.representedObject = AppearanceMode.dark.rawValue
        menu.addItem(.separator())
        let fullScreen = menu.addItem(withTitle: "Enter Full Screen",
                                      action: #selector(NSWindow.toggleFullScreen(_:)),
                                      keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private static func conversationMenu() -> NSMenu {
        let menu = NSMenu(title: "Conversation")
        menu.addItem(withTitle: "Send",
                     action: #selector(ConversationMenuActions.sendConversationMessage(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Interrupt",
                     action: #selector(ConversationMenuActions.interruptConversation(_:)),
                     keyEquivalent: ".")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Branch",
                     action: #selector(ConversationMenuActions.branchConversation(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Rename…",
                     action: #selector(ConversationMenuActions.renameConversation(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Archive",
                     action: #selector(ConversationMenuActions.archiveConversation(_:)),
                     keyEquivalent: "")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Hermes Help",
                     action: #selector(NSApplication.showHelp(_:)),
                     keyEquivalent: "?")
        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
