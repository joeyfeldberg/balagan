import SwiftUI
import BalaganCore

/// Centralized visual design tokens (dark-first). See the redesign spec: a deliberate
/// background → surface → raised-surface elevation ramp + hairline borders + status/priority color
/// language, replacing the flat single-gray look.
enum Theme {
    /// The theme the chrome draws with. Set by `BoardViewModel.appThemeID` (and `BALAGAN_THEME` for a
    /// snapshot); the root view is rebuilt on a change, so every token below is re-read.
    nonisolated(unsafe) static var current: AppTheme = AppThemes.balagan

    private static var palette: ThemePalette { current.palette }
    static var isDark: Bool { current.isDark }

    // Surface elevation ramp: window → surface → raised, plus hover.
    static var bgWindow: Color { Color(palette.window) }
    static var surface: Color { Color(palette.surface) }
    static var surfaceRaised: Color { Color(palette.surfaceRaised) }
    static var surfaceHover: Color { Color(palette.surfaceHover) }

    // Borders / separators
    static var hairline: Color { Color(palette.hairline) }
    static var hairlineStrong: Color { Color(palette.hairlineStrong) }

    /// The theme's accent, or the macOS accent for themes that don't set one.
    static var accent: Color { palette.accent.map { Color($0) } ?? Color.accentColor }
    static var accentSoft: Color { accent.opacity(0.14) }

    /// "An agent is blocked on you" — one amber, shared by every place waiting is drawn (task card,
    /// sidebar project row, terminal tab, titlebar badge) so the state reads the same everywhere.
    static let agentWaiting = Color(red: 0.95, green: 0.55, blue: 0.15)
    /// Something live or passing: an installed agent, a running server, green CI, an approved review.
    static let positive = Color(red: 0.25, green: 0.73, blue: 0.44)
    /// Something failed or gone: red CI, a closed PR, requested changes, a missing worktree.
    static let negative = Color(red: 0.88, green: 0.36, blue: 0.36)

    // Text: fixed colors from the theme rather than the dynamic system label colors, so text matches
    // the theme's surfaces under any system appearance and renders the same in ImageRenderer snapshots.
    static var textPrimary: Color { Color(palette.textPrimary) }
    static var textSecondary: Color { Color(palette.textSecondary) }
    static var textTertiary: Color { Color(palette.textTertiary) }

    /// The SwiftUI color scheme matching the theme, for controls and snapshots.
    static var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// The type scale. Every text size in the chrome is one of these (times the UI scale), so rows,
    /// cards, the header and the panes line up instead of drifting across 10 / 10.5 / 11 / 11.5…
    enum TextSize {
        /// Section caps, badges, counts.
        static let micro: CGFloat = 10.5
        /// Metadata and secondary lines.
        static let small: CGFloat = 11.5
        /// Rows and content.
        static let body: CGFloat = 12.5
        /// Card, project and header titles.
        static let title: CGFloat = 13.5
        /// Empty-state titles.
        static let heading: CGFloat = 15
    }

    // Radii
    static let radiusChip: CGFloat = 5
    static let radiusCard: CGFloat = 8
    static let radiusColumn: CGFloat = 10
    static let radiusButton: CGFloat = 6
    static let radiusSelectionBar: CGFloat = 2   // the leading accent bar on a selected row/card
}

extension Color {
    init(_ themeColor: ThemeColor) {
        self = Color(.sRGB, red: themeColor.red, green: themeColor.green, blue: themeColor.blue, opacity: themeColor.alpha)
    }

    /// Builds a color from a `RRGGBB` hex string (no leading `#`). Falls back to a neutral slate on a
    /// malformed value so a bad lane color can never crash rendering.
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = Color(red: 138 / 255, green: 147 / 255, blue: 166 / 255)
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Lane {
    /// The column's accent color, from its editable hex.
    var color: Color { Color(hexString: colorHex) }
}

extension TaskStatus {
    /// Default accent for the built-in lanes, and a stable fallback for a custom id — used only by fixed
    /// chrome (e.g. the titlebar badge). Kanban columns use their own `Lane.color`.
    var color: Color {
        switch rawValue {
        case "doing": return Color(hexString: "4C8DFF")
        case "done": return Color(hexString: "3FB970")
        case "parked": return Color(hexString: "C98A2B")
        default: return Color(hexString: "8A93A6")  // todo + any custom id
        }
    }
}

extension TaskPriority {
    var tint: Color {
        switch self {
        case .high: return Color(red: 255 / 255, green: 107 / 255, blue: 107 / 255)   // #FF6B6B
        case .medium: return Color(red: 224 / 255, green: 162 / 255, blue: 60 / 255)  // #E0A23C
        case .low: return Color(red: 91 / 255, green: 185 / 255, blue: 122 / 255)     // #5BB97A
        }
    }

    var fill: Color { tint.opacity(0.18) }
}
