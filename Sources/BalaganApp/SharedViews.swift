import SwiftUI
import BalaganCore

// Small view components shared across the board chrome. Extracted from the form sheets, titlebar
// controls, sidebar, and task card so the copies live in one place. Each is a behavior-preserving
// extraction — the rendered output is identical to the inlined originals.

/// The Save/Cancel footer shared by the form sheets. `.prominent` (project / task) sits on a
/// surface-filled bar with a top hairline and a bordered-prominent Save; `.plain` (surface-tab
/// forms) is a bare trailing row with default spacing. The button labels ("Cancel" / "Save") and
/// Cancel's help ("Discard changes") are invariant across all four sheets; the accessibility
/// identifiers, Save help, and disabled state vary and are passed in. Cancel dismisses; Save runs
/// `onSave` then dismisses.
struct SheetFooter: View {
    enum Style { case prominent, plain }

    @Environment(\.dismiss) private var dismiss
    var style: Style = .plain
    let cancelIdentifier: String
    let saveHelp: String
    let saveDisabled: Bool
    let saveIdentifier: String
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: style == .prominent ? 10 : nil) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("Discard changes")
                .accessibilityIdentifier(cancelIdentifier)

            saveButton
        }
        .modifier(SheetFooterChrome(active: style == .prominent))
    }

    @ViewBuilder
    private var saveButton: some View {
        switch style {
        case .prominent:
            saveButtonBase.buttonStyle(.borderedProminent)
        case .plain:
            saveButtonBase
        }
    }

    private var saveButtonBase: some View {
        Button("Save") {
            onSave()
            dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(saveDisabled)
        .help(saveHelp)
        .accessibilityIdentifier(saveIdentifier)
    }
}

/// The surface-filled footer bar (padding + background + top hairline) worn by the prominent sheets.
private struct SheetFooterChrome: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Theme.surface)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
        } else {
            content
        }
    }
}

/// The 3pt leading accent bar marking a selected sidebar project row / task card. Placed as a
/// leading overlay by the caller; `verticalInset` is the (already scaled) vertical padding.
struct SelectionAccentBar: View {
    let isSelected: Bool
    let verticalInset: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radiusSelectionBar, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 3)
            .padding(.vertical, verticalInset)
            .opacity(isSelected ? 1 : 0)
    }
}

/// A borderless titlebar `Menu` whose SF Symbol carries a small count pill in its top-trailing
/// corner (shown when `count > 0`, capped at 99). The badge geometry/styling is shared by the
/// agent-sessions and notifications menus; the icon, count, pill color, menu content, and help
/// differ per call and are passed in.
struct BadgedMenu<Content: View>: View {
    let systemImage: String
    let count: Int
    let badgeColor: Color
    /// An optional second, differently-coloured count pinned to the opposite corner — used by the
    /// agents menu to distinguish "working" (top, green) from "waiting on you" (bottom, amber)
    /// without hiding either behind a single number.
    var secondaryCount: Int = 0
    var secondaryBadgeColor: Color = .orange
    let help: String
    @ViewBuilder var content: Content

    private func badge(_ value: Int, color: Color) -> some View {
        Text("\(min(value, 99))")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 2)
            .frame(minWidth: 12, minHeight: 12)
            .background(Circle().fill(color))
    }

    var body: some View {
        Menu {
            content
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .frame(width: 24, height: 22)
                if count > 0 {
                    badge(count, color: badgeColor)
                        .offset(x: 4, y: -2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if secondaryCount > 0 {
                    badge(secondaryCount, color: secondaryBadgeColor)
                        .offset(x: 4, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

/// A `TextEditor` with a greyed placeholder shown while empty, wearing the shared form-field chrome.
/// Generic over the focus enum so each sheet keeps binding to its own `@FocusState` field.
struct PlaceholderTextEditor<Field: Hashable>: View {
    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat
    var monospaced: Bool = false
    let identifier: String
    @FocusState.Binding var focus: Field?
    let field: Field

    private var font: Font {
        monospaced ? .system(.body, design: .monospaced) : .body
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(font)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .focused($focus, equals: field)
                .accessibilityIdentifier(identifier)

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .formFieldChrome(focused: focus == field)
    }
}
