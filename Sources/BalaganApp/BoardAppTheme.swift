import AppKit
import SwiftUI
import BalaganCore

/// Switching the app theme. The chrome reads `Theme` tokens, which follow `Theme.current`; the windows'
/// roots are wrapped in `ThemedRoot`, which rebuilds them when the theme changes.
extension BoardViewModel {
    /// Picks a theme from Settings or the palette and remembers it.
    func selectAppTheme(_ id: String) {
        AppPreferences.appThemeID = id
        appThemeID = id
    }

    /// Turns the terminals' theme colors on or off and applies it to the open terminals.
    func setThemeTerminals(_ on: Bool) {
        AppPreferences.themeTerminals = on
        applyAppTheme()
    }

    func applyAppTheme() {
        Theme.current = AppThemes.named(appThemeID)
        // Terminals: the theme's Ghostty colors, or the user's own. Running terminals reload live; the
        // overrides file is what every new one reads (in ui-test mode there are no real terminals).
        let terminalTheme = AppPreferences.themeTerminals ? Theme.current.ghosttyTheme : nil
        if terminalTheme != GhosttyConfigOverrides.terminalTheme {
            GhosttyConfigOverrides.terminalTheme = terminalTheme
            if getenv("GHOSTTY_RESOURCES_DIR") != nil {
                GhosttyConfigOverrides.install()
                // Theme changes come from the UI, on the main thread.
                MainActor.assumeIsolated { TerminalHostRegistry.shared.reloadGhosttyConfig() }
            }
        }
        let appearance = NSAppearance(named: Theme.isDark ? .darkAqua : .aqua)
        for window in NSApp?.windows ?? [] where window.styleMask.contains(.titled) {
            window.appearance = appearance
        }
    }
}

/// A window's root view, rebuilt whenever the app theme changes so every `Theme` token is read again.
/// It also gives system controls the theme's color scheme and accent.
struct ThemedRoot<Content: View>: View {
    @ObservedObject var viewModel: BoardViewModel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .id(viewModel.appThemeID)
            .environment(\.colorScheme, Theme.colorScheme)
            .tint(Theme.accent)
    }
}
