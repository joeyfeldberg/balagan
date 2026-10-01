import SwiftUI
import BalaganCore

/// Centralized visual design tokens (dark-first). See the redesign spec: a deliberate
/// background → surface → raised-surface elevation ramp + hairline borders + status/priority color
/// language, replacing the flat single-gray look.
enum Theme {
    // Surface elevation ramp (dark)
    static let bgWindow = Color(red: 22 / 255, green: 23 / 255, blue: 26 / 255)        // #16171A
    static let surface = Color(red: 29 / 255, green: 31 / 255, blue: 35 / 255)         // #1D1F23
    static let surfaceRaised = Color(red: 38 / 255, green: 40 / 255, blue: 46 / 255)   // #26282E
    static let surfaceHover = Color(red: 46 / 255, green: 49 / 255, blue: 56 / 255)    // #2E3138

    // Borders / separators
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)

    // Accent (rides the macOS system accent)
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.14)

    /// "An agent is blocked on you" — one amber, shared by every place waiting is drawn (task card,
    /// sidebar project row, terminal tab, titlebar badge) so the state reads the same everywhere.
    static let agentWaiting = Color(red: 0.95, green: 0.55, blue: 0.15)

    // Text — fixed light-on-dark values (mirroring macOS dark label colors) rather than the dynamic
    // system label colors. The surface ramp is fixed-dark, so the UI is dark-only by design; fixed
    // text keeps it correct under any system appearance AND renders correctly in ImageRenderer
    // snapshots (dynamic label colors resolve to black in the renderer's default light appearance).
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.56)
    static let textTertiary = Color.white.opacity(0.34)

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
