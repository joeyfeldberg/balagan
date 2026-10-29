import SwiftUI
import BalaganCore

/// A label + segmented −/value/+ pill + quiet inline Reset. Shared by the UI-scale and terminal-font rows.
struct SettingsStepperRow: View {
    let label: String
    let value: String
    let isAtDefault: Bool
    let scale: CGFloat
    let decreaseID: String
    let valueID: String
    let increaseID: String
    let resetID: String
    let onDecrease: () -> Void
    let onIncrease: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 12 * scale) {
            Text(label)
                .font(.system(size: 13 * scale))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                SettingsStepperButton(systemName: "minus", scale: scale, action: onDecrease)
                    .accessibilityIdentifier(decreaseID)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 24 * scale)
                Text(value)
                    .font(.system(size: 12 * scale, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 48 * scale)
                    .accessibilityIdentifier(valueID)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 24 * scale)
                SettingsStepperButton(systemName: "plus", scale: scale, action: onIncrease)
                    .accessibilityIdentifier(increaseID)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                    .fill(Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous))

            Button("Reset", action: onReset)
                .buttonStyle(.plain)
                .font(.system(size: 12 * scale))
                .help("Reset to default")
                .foregroundStyle(isAtDefault ? Theme.textTertiary : Theme.textSecondary)
                .disabled(isAtDefault)
                .accessibilityIdentifier(resetID)
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 8 * scale)
        .frame(minHeight: 32 * scale)
    }
}

private struct SettingsStepperButton: View {
    let systemName: String
    let scale: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28 * scale, height: 24 * scale)
                .background(isHovered ? Theme.surfaceHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// Settings → Prompts: the global saved prompts every task offers (a project can add its own).
struct GlobalPromptsPage: View {
    @AppStorage(AppPreferences.Keys.savedPrompts) private var stored: String?
    @State private var prompts: [SavedPrompt] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One click sends a prompt to a task's agent: from the task's ⋯ menu, a card's right-click menu, or the command palette. Projects can add their own in their settings.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            SavedPromptsEditor(prompts: $prompts)
            Button("Restore Defaults") {
                prompts = SavedPrompts.defaults
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .onAppear {
            prompts = SavedPrompts.decode(stored)
            loaded = true
        }
        .onChange(of: prompts) { _, newValue in
            guard loaded else { return }
            stored = SavedPrompts.encode(newValue)
        }
    }
}
