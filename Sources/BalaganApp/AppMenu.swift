import AppKit

/// Installs a standard main menu. The app launches as a bare executable with a programmatic
/// `NSApplication`, so without this there is no Edit menu — and the standard editing shortcuts
/// (⌘C/⌘V/⌘X/⌘A/⌘Z) are dispatched *through* the main menu, so they wouldn't work in text fields.
/// Items use nil targets so AppKit routes them down the responder chain to the focused control
/// (a form field's field editor, or the terminal host view which implements copy:/paste:).
enum AppMenu {
    @MainActor
    static func install(appName: String = "Balagan") {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Nil target: the responder chain ends at the app delegate, which opens the Settings window.
        appMenu.addItem(withTitle: "Settings…", action: Selector(("showSettingsWindow:")), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        // Edit menu — the reason this exists: gives the standard editing shortcuts somewhere to live.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
