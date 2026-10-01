import AppKit
import SwiftUI

/// Settings as a real window (⌘,) instead of a sheet over the board: it doesn't block the app, opens
/// from anywhere, and reopening brings the same window forward.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(viewModel: BoardViewModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsSheet(viewModel: viewModel)
            .environment(\.balaganUIScale, CGFloat(viewModel.uiAppearance.uiScale))
            .environment(\.colorScheme, .dark)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("BalaganSettings")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

extension BalaganApplication {
    /// App menu → Settings… (⌘,). Reached through the responder chain (nil-targeted menu item).
    @objc @MainActor func showSettingsWindow(_ sender: Any?) {
        guard let viewModel else { return }
        SettingsWindowController.shared.show(viewModel: viewModel)
    }
}
