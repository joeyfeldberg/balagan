import Foundation

/// An RGBA color with components in 0…1, kept free of SwiftUI so themes stay pure and testable.
public struct ThemeColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From `RRGGBB` (a leading `#` is fine). A malformed value gives mid grey rather than failing.
    public init(hex: String, alpha: Double = 1) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = cleaned.count == 6 ? UInt32(cleaned, radix: 16) ?? 0x808080 : 0x808080
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static let white = ThemeColor(red: 1, green: 1, blue: 1)

    /// This color moved `amount` (0…1) of the way toward `other`. Alpha stays this color's.
    public func mixed(with other: ThemeColor, _ amount: Double) -> ThemeColor {
        ThemeColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            alpha: alpha
        )
    }

    public func withAlpha(_ alpha: Double) -> ThemeColor {
        ThemeColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Relative luminance (WCAG), for telling light backgrounds from dark ones.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

/// Every color the app's chrome draws with, resolved for one theme.
public struct ThemePalette: Equatable, Sendable {
    /// The window and the terminal pane behind it.
    public var window: ThemeColor
    /// Kanban columns, the sidebar's panels.
    public var surface: ThemeColor
    /// Cards and chips that sit on a surface.
    public var surfaceRaised: ThemeColor
    public var surfaceHover: ThemeColor
    public var hairline: ThemeColor
    public var hairlineStrong: ThemeColor
    public var textPrimary: ThemeColor
    public var textSecondary: ThemeColor
    public var textTertiary: ThemeColor
    /// nil follows the macOS accent color.
    public var accent: ThemeColor?

    public init(
        window: ThemeColor, surface: ThemeColor, surfaceRaised: ThemeColor, surfaceHover: ThemeColor,
        hairline: ThemeColor, hairlineStrong: ThemeColor,
        textPrimary: ThemeColor, textSecondary: ThemeColor, textTertiary: ThemeColor,
        accent: ThemeColor?
    ) {
        self.window = window
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.surfaceHover = surfaceHover
        self.hairline = hairline
        self.hairlineStrong = hairlineStrong
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
    }

    /// The chrome for a theme given only its background, text color and accent, so it sits seamlessly
    /// around a terminal using the same colors. Dark themes step their surfaces toward the text color.
    /// Light themes put cards above the background (whiter) and columns below it, the usual light look.
    public static func derived(background: ThemeColor, foreground: ThemeColor, accent: ThemeColor?) -> ThemePalette {
        let isDark = background.luminance < 0.4
        if isDark {
            return ThemePalette(
                window: background,
                surface: background.mixed(with: foreground, 0.035),
                surfaceRaised: background.mixed(with: foreground, 0.08),
                surfaceHover: background.mixed(with: foreground, 0.12),
                hairline: foreground.withAlpha(0.09),
                hairlineStrong: foreground.withAlpha(0.16),
                textPrimary: foreground.withAlpha(0.95),
                textSecondary: foreground.withAlpha(0.62),
                textTertiary: foreground.withAlpha(0.42),
                accent: accent
            )
        }
        let raised = background.mixed(with: .white, 0.7)
        return ThemePalette(
            window: background,
            surface: background.mixed(with: foreground, 0.045),
            surfaceRaised: raised,
            surfaceHover: raised.mixed(with: foreground, 0.06),
            hairline: foreground.withAlpha(0.12),
            hairlineStrong: foreground.withAlpha(0.2),
            textPrimary: foreground.withAlpha(0.95),
            textSecondary: foreground.withAlpha(0.68),
            textTertiary: foreground.withAlpha(0.48),
            accent: accent
        )
    }
}

/// A look for the whole app: its chrome palette and, optionally, the Ghostty theme its terminals use.
public struct AppTheme: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let palette: ThemePalette
    /// The Ghostty theme (a file in Ghostty.app's `themes` folder) the terminals switch to. nil keeps
    /// the user's own Ghostty colors.
    public let ghosttyTheme: String?

    public var isDark: Bool { palette.window.luminance < 0.4 }

    public init(id: String, name: String, palette: ThemePalette, ghosttyTheme: String?) {
        self.id = id
        self.name = name
        self.palette = palette
        self.ghosttyTheme = ghosttyTheme
    }

    /// A theme drawn from a Ghostty theme's background, foreground and an accent picked from its palette.
    public init(id: String, name: String, ghostty: String, background: String, foreground: String, accent: String) {
        self.init(
            id: id,
            name: name,
            palette: .derived(
                background: ThemeColor(hex: background),
                foreground: ThemeColor(hex: foreground),
                accent: ThemeColor(hex: accent)
            ),
            ghosttyTheme: ghostty
        )
    }
}

/// The themes Balagan ships. Each one after the two Balagan themes is matched to a Ghostty theme of the
/// same name, with the chrome taken from that theme's own colors.
public enum AppThemes {
    /// Today's look, exactly: the fixed dark ramp, white text, the macOS accent, and the user's own
    /// Ghostty colors in the terminals.
    public static let balagan = AppTheme(
        id: "balagan",
        name: "Balagan",
        palette: ThemePalette(
            window: ThemeColor(hex: "16171A"),
            surface: ThemeColor(hex: "1D1F23"),
            surfaceRaised: ThemeColor(hex: "26282E"),
            surfaceHover: ThemeColor(hex: "2E3138"),
            hairline: ThemeColor.white.withAlpha(0.08),
            hairlineStrong: ThemeColor.white.withAlpha(0.14),
            textPrimary: ThemeColor.white.withAlpha(0.92),
            textSecondary: ThemeColor.white.withAlpha(0.56),
            textTertiary: ThemeColor.white.withAlpha(0.34),
            accent: nil
        ),
        ghosttyTheme: nil
    )

    /// A light counterpart to the default, also on the macOS accent and the user's Ghostty colors.
    public static let balaganLight = AppTheme(
        id: "balagan-light",
        name: "Balagan Light",
        palette: .derived(background: ThemeColor(hex: "F4F4F6"), foreground: ThemeColor(hex: "1D1D22"), accent: nil),
        ghosttyTheme: nil
    )

    public static let all: [AppTheme] = [
        balagan,
        balaganLight,
        AppTheme(id: "catppuccin-mocha", name: "Catppuccin Mocha", ghostty: "Catppuccin Mocha", background: "1e1e2e", foreground: "cdd6f4", accent: "89b4fa"),
        AppTheme(id: "catppuccin-macchiato", name: "Catppuccin Macchiato", ghostty: "Catppuccin Macchiato", background: "24273a", foreground: "cad3f5", accent: "8aadf4"),
        AppTheme(id: "tokyo-night", name: "Tokyo Night", ghostty: "TokyoNight", background: "1a1b26", foreground: "c0caf5", accent: "7aa2f7"),
        AppTheme(id: "tokyo-night-storm", name: "Tokyo Night Storm", ghostty: "TokyoNight Storm", background: "24283b", foreground: "c0caf5", accent: "7aa2f7"),
        AppTheme(id: "dracula", name: "Dracula", ghostty: "Dracula", background: "282a36", foreground: "f8f8f2", accent: "bd93f9"),
        AppTheme(id: "nord", name: "Nord", ghostty: "Nord", background: "2e3440", foreground: "d8dee9", accent: "88c0d0"),
        AppTheme(id: "gruvbox-dark", name: "Gruvbox Dark", ghostty: "Gruvbox Dark", background: "282828", foreground: "ebdbb2", accent: "83a598"),
        AppTheme(id: "one-dark", name: "One Dark", ghostty: "Atom One Dark", background: "21252b", foreground: "abb2bf", accent: "61afef"),
        AppTheme(id: "rose-pine", name: "Rosé Pine", ghostty: "Rose Pine", background: "191724", foreground: "e0def4", accent: "c4a7e7"),
        AppTheme(id: "rose-pine-moon", name: "Rosé Pine Moon", ghostty: "Rose Pine Moon", background: "232136", foreground: "e0def4", accent: "c4a7e7"),
        AppTheme(id: "kanagawa", name: "Kanagawa", ghostty: "Kanagawa Wave", background: "1f1f28", foreground: "dcd7ba", accent: "7e9cd8"),
        AppTheme(id: "everforest-dark", name: "Everforest Dark", ghostty: "Everforest Dark Hard", background: "1e2326", foreground: "d3c6aa", accent: "a7c080"),
        AppTheme(id: "github-dark", name: "GitHub Dark", ghostty: "GitHub Dark Default", background: "0d1117", foreground: "e6edf3", accent: "58a6ff"),
        AppTheme(id: "solarized-dark", name: "Solarized Dark", ghostty: "iTerm2 Solarized Dark", background: "002b36", foreground: "93a1a1", accent: "268bd2"),
        AppTheme(id: "monokai-pro", name: "Monokai Pro", ghostty: "Monokai Pro", background: "2d2a2e", foreground: "fcfcfa", accent: "78dce8"),
        AppTheme(id: "catppuccin-latte", name: "Catppuccin Latte", ghostty: "Catppuccin Latte", background: "eff1f5", foreground: "4c4f69", accent: "1e66f5"),
        AppTheme(id: "github-light", name: "GitHub Light", ghostty: "GitHub Light Default", background: "ffffff", foreground: "1f2328", accent: "0969da"),
        AppTheme(id: "solarized-light", name: "Solarized Light", ghostty: "iTerm2 Solarized Light", background: "fdf6e3", foreground: "586e75", accent: "268bd2"),
        AppTheme(id: "rose-pine-dawn", name: "Rosé Pine Dawn", ghostty: "Rose Pine Dawn", background: "faf4ed", foreground: "575279", accent: "907aa9"),
        AppTheme(id: "gruvbox-light", name: "Gruvbox Light", ghostty: "Gruvbox Light", background: "fbf1c7", foreground: "3c3836", accent: "076678"),
        AppTheme(id: "tokyo-night-day", name: "Tokyo Night Day", ghostty: "TokyoNight Day", background: "e1e2e7", foreground: "3760bf", accent: "2e7de9"),
    ]

    /// The theme with this id, or the default for nil or an id no longer shipped.
    public static func named(_ id: String?) -> AppTheme {
        all.first { $0.id == id } ?? balagan
    }
}
