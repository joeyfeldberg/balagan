import AppKit
import SwiftUI
import BalaganCore

/// Settings → Shortcuts: every rebindable action, recorded by clicking its chord and pressing a new
/// one. The recorder's key monitor lives with this page, so leaving the page always removes it.
struct ShortcutsSettingsPage: View {
    @ObservedObject var viewModel: BoardViewModel
    let scale: CGFloat
    @State private var recordingAction: ShortcutAction?
    @State private var recordMonitor: Any?
    @State private var recordError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shortcuts")
                    .font(.system(size: Theme.TextSize.heading * scale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Reset All") {
                    stopRecording()
                    viewModel.resetAllShortcuts()
                }
                .buttonStyle(.plain)
                .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                .foregroundStyle(Theme.accent)
                .help("Restore every shortcut to its default")
                .accessibilityIdentifier("reset-all-shortcuts-button")
            }
            .padding(.horizontal, SettingsLayout.inset * scale)
            .padding(.top, 18 * scale)
            .padding(.bottom, 4 * scale)

            Text(recordingAction == nil
                ? "Click a shortcut, then press the new key combination."
                : (recordError ?? "Press the new shortcut — or Esc to cancel."))
                .font(.system(size: Theme.TextSize.small * scale))
                .foregroundStyle(recordError == nil ? Theme.textTertiary : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsLayout.inset * scale)
                .padding(.bottom, 6 * scale)

            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Text(group.rawValue.uppercased())
                    .font(.system(size: Theme.TextSize.micro * scale, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsLayout.inset * scale)
                    .padding(.top, 12 * scale)
                    .padding(.bottom, 2 * scale)

                ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                    shortcutRow(action, scale: scale)
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private func shortcutRow(_ action: ShortcutAction, scale: CGFloat) -> some View {
        let chord = viewModel.keyboardShortcuts.chord(for: action)
        let isRecording = recordingAction == action
        let customized = viewModel.keyboardShortcuts.isCustomized(action)
        let conflict = viewModel.keyboardShortcuts.action(boundTo: chord, excluding: action)

        HStack(spacing: 8 * scale) {
            Text(action.displayName)
                .font(.system(size: Theme.TextSize.body * scale))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8 * scale)

            if let conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10 * scale))
                    .foregroundStyle(.orange)
                    .help("Also bound to \(conflict.displayName)")
            }

            Button {
                if isRecording { stopRecording() } else { startRecording(action) }
            } label: {
                Text(isRecording ? "Press keys…" : chord.displayString)
                    .font(.system(size: Theme.TextSize.body * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(isRecording ? Theme.accent : Theme.textPrimary)
                    .frame(minWidth: 74 * scale)
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 4 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 6 * scale)
                            .fill(isRecording ? Theme.accent.opacity(0.12) : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6 * scale)
                            .strokeBorder(isRecording ? Theme.accent : Theme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Click, then press a new key combination")
            .accessibilityIdentifier("shortcut-\(action.rawValue)-button")

            Button {
                stopRecording()
                viewModel.resetShortcut(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10 * scale))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .opacity(customized ? 1 : 0)
            .disabled(customized == false)
            .help("Reset to default")
        }
        .padding(.horizontal, SettingsLayout.inset * scale)
        .padding(.vertical, 4 * scale)
    }

    /// Begin capturing the next key combination for `action` via a local key-down monitor. The monitor
    /// swallows every key while recording so nothing leaks into the UI; Esc cancels.
    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        recordError = nil
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            guard let chord = KeyChord.from(event: event) else {
                return nil // ignore keys we can't represent
            }
            guard chord.isValid else {
                recordError = "Shortcuts must include ⌘, ⌃, or ⌥."
                return nil
            }
            viewModel.updateShortcut(action, to: chord)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = recordMonitor {
            NSEvent.removeMonitor(monitor)
            recordMonitor = nil
        }
        recordingAction = nil
    }
}
