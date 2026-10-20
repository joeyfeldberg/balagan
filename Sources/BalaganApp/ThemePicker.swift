import SwiftUI
import BalaganCore

/// Settings → Appearance: every theme as a small picture of the board in its colors, dark ones first.
struct ThemePicker: View {
    let selectedID: String
    let scale: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            group("Dark", AppThemes.all.filter(\.isDark))
            group("Light", AppThemes.all.filter { $0.isDark == false })
        }
    }

    private func group(_ title: String, _ themes: [AppTheme]) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(title.uppercased())
                .font(.system(size: Theme.TextSize.micro * scale, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132 * scale), spacing: 10 * scale)], spacing: 12 * scale) {
                ForEach(themes) { theme in
                    ThemeSwatch(theme: theme, isSelected: theme.id == selectedID, scale: scale)
                        .onTapGesture { onSelect(theme.id) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(.default) { onSelect(theme.id) }
                        .accessibilityIdentifier("theme-\(theme.id)")
                }
            }
        }
    }
}

/// One theme drawn in its own colors: a sidebar strip, a column with two cards, the accent and the
/// waiting amber, so you can judge it before switching.
private struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let scale: CGFloat

    private var palette: ThemePalette { theme.palette }
    private var accent: Color { palette.accent.map { Color($0) } ?? Color.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            preview
                .frame(height: 70 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .stroke(isSelected ? Theme.accent : Theme.hairlineStrong, lineWidth: isSelected ? 2 : 1)
                )
            HStack(spacing: 4 * scale) {
                Text(theme.name)
                    .font(.system(size: Theme.TextSize.small * scale, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .contentShape(Rectangle())
        .help(theme.ghosttyTheme.map { "\(theme.name) · terminals use Ghostty's \"\($0)\"" }
            ?? "\(theme.name) · terminals keep your Ghostty colors")
    }

    private var preview: some View {
        HStack(spacing: 0) {
            // Sidebar: a selected row in the accent, then plain rows.
            VStack(alignment: .leading, spacing: 4 * scale) {
                RoundedRectangle(cornerRadius: 2 * scale).fill(accent.opacity(0.5)).frame(width: 22 * scale, height: 4 * scale)
                line(width: 18)
                line(width: 24)
                line(width: 14)
            }
            .padding(6 * scale)
            .frame(width: 36 * scale, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(palette.window))

            // A column holding a waiting card and a running one.
            VStack(alignment: .leading, spacing: 4 * scale) {
                card(edge: Theme.agentWaiting)
                card(edge: nil)
            }
            .padding(5 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(palette.surface))
            .padding(5 * scale)
            .background(Color(palette.window))
        }
    }

    private func line(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2 * scale)
            .fill(Color(palette.textTertiary))
            .frame(width: width * scale, height: 3 * scale)
    }

    private func card(edge: Color?) -> some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            RoundedRectangle(cornerRadius: 2 * scale).fill(Color(palette.textPrimary)).frame(width: 40 * scale, height: 3.5 * scale)
            HStack(spacing: 3 * scale) {
                RoundedRectangle(cornerRadius: 2 * scale).fill(edge ?? accent).frame(width: 12 * scale, height: 3 * scale)
                RoundedRectangle(cornerRadius: 2 * scale).fill(Color(palette.textSecondary)).frame(width: 26 * scale, height: 3 * scale)
            }
        }
        .padding(5 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(palette.surfaceRaised))
        .overlay(alignment: .leading) {
            if let edge { Rectangle().fill(edge).frame(width: 2 * scale) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3 * scale, style: .continuous))
    }
}
