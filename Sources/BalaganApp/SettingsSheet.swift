import AppKit
import SwiftUI
import BalaganCore

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case agents = "Agents"
    case notifications = "Notifications"
    case terminal = "Terminal"
    case speech = "Speech"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "sparkles"
        case .notifications: return "bell.badge"
        case .terminal: return "terminal"
        case .speech: return "speaker.wave.2"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var viewModel: BoardViewModel
    @Environment(\.balaganUIScale) private var balaganUIScale
    @State private var presentationScale: CGFloat?
    // Env hook lets the headless snapshot harness open a specific category (`BALAGAN_SETTINGS_CATEGORY`).
    @State private var selectedCategory: SettingsCategory =
        SettingsCategory(rawValue: ProcessInfo.processInfo.environment["BALAGAN_SETTINGS_CATEGORY"] ?? "") ?? .general
    @AppStorage(AppPreferences.Keys.defaultAgent) private var defaultAgentRaw = AppPreferences.defaultAgent.rawValue
    @AppStorage(AppPreferences.Keys.waitingBanners) private var waitingBanners = true
    @AppStorage(AppPreferences.Keys.finishedBanners) private var finishedBanners = true
    @State private var recordingAction: ShortcutAction?
    @State private var recordMonitor: Any?
    @State private var recordError: String?

    var body: some View {
        let fixedScale = presentationScale ?? balaganUIScale

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                categorySidebar(scale: fixedScale)

                Rectangle().fill(Theme.hairline).frame(width: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        categoryContent(scale: fixedScale)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16 * fixedScale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.bgWindow)
            }

        }
        .frame(width: 640 * fixedScale, height: 460 * fixedScale)
        .background(Theme.bgWindow)
        .onChange(of: selectedCategory) { _, _ in stopRecording() }
        .onAppear {
            if presentationScale == nil {
                presentationScale = balaganUIScale
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: Category sidebar

    private func categorySidebar(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Color.clear.frame(height: 10 * scale)

            ForEach(SettingsCategory.allCases) { category in
                let selected = category == selectedCategory
                Button {
                    selectedCategory = category
                } label: {
                    HStack(spacing: 9 * scale) {
                        Image(systemName: category.icon)
                            .font(.system(size: 12 * scale))
                            .frame(width: 16 * scale)
                            .foregroundStyle(selected ? Color.accentColor : Theme.textSecondary)
                        Text(category.rawValue)
                            .font(.system(size: 13 * scale, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9 * scale)
                    .padding(.vertical, 6 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                            .fill(selected ? Theme.accentSoft : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-category-\(category.rawValue.lowercased())")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8 * scale)
        .frame(width: 158 * scale)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    // MARK: Category content

    @ViewBuilder
    private func categoryContent(scale: CGFloat) -> some View {
        switch selectedCategory {
        case .general:
            contentHeader("General", scale: scale)
            SettingsStepperRow(
                label: "Tasks & header scale",
                value: "\(Int((viewModel.uiAppearance.uiScale * 100).rounded()))%",
                isAtDefault: abs(viewModel.uiAppearance.uiScale - 1.0) < 0.001,
                scale: scale,
                decreaseID: "decrease-ui-scale-button",
                valueID: "ui-scale-value",
                increaseID: "increase-ui-scale-button",
                resetID: "reset-ui-scale-button",
                onDecrease: { viewModel.decreaseUIScale() },
                onIncrease: { viewModel.increaseUIScale() },
                onReset: { viewModel.resetUIScale() }
            )
            SettingsStepperRow(
                label: "Sidebar scale",
                value: "\(Int((viewModel.uiAppearance.effectiveSidebarScale * 100).rounded()))%",
                isAtDefault: abs(viewModel.uiAppearance.effectiveSidebarScale - 1.0) < 0.001,
                scale: scale,
                decreaseID: "decrease-sidebar-scale-button",
                valueID: "sidebar-scale-value",
                increaseID: "increase-sidebar-scale-button",
                resetID: "reset-sidebar-scale-button",
                onDecrease: { viewModel.decreaseSidebarScale() },
                onIncrease: { viewModel.increaseSidebarScale() },
                onReset: { viewModel.resetSidebarScale() }
            )
            autoSleepRow(scale: scale)
        case .agents:
            contentHeader("Agents", scale: scale)
            agentsSection(scale: scale)
        case .notifications:
            contentHeader("Notifications", scale: scale)
            notificationsSection(scale: scale)
        case .terminal:
            contentHeader("Terminal", scale: scale)
            SettingsStepperRow(
                label: "Font size",
                value: "\(Int(viewModel.terminalAppearance.fontSize)) pt",
                isAtDefault: abs(viewModel.terminalAppearance.fontSize - TerminalAppearanceSettings.defaultFontSize) < 0.001,
                scale: scale,
                decreaseID: "decrease-terminal-font-button",
                valueID: "terminal-font-value",
                increaseID: "increase-terminal-font-button",
                resetID: "reset-terminal-font-button",
                onDecrease: { applyTerminalFontZoom("decrease_font_size:1", viewModel.decreaseTerminalFontSize()) },
                onIncrease: { applyTerminalFontZoom("increase_font_size:1", viewModel.increaseTerminalFontSize()) },
                onReset: { applyTerminalFontZoom("reset_font_size", viewModel.resetTerminalFontSize()) }
            )
            ghosttyInfoRow(scale: scale)
        case .speech:
            contentHeader("Speech", scale: scale)
            speechSection(scale: scale)
        case .shortcuts:
            shortcutsSection(scale: scale)
        }
    }

    // MARK: Agents section

    @ViewBuilder
    private func agentsSection(scale: CGFloat) -> some View {
        settingsRow("Default agent for new projects", scale: scale) {
            Picker("", selection: $defaultAgentRaw) {
                ForEach(AppPreferences.DefaultAgent.allCases) { agent in
                    Text(agent.title).tag(agent.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("default-agent-picker")
        }
        settingsNote("Pre-fills the agent command when you add a project. Each project can change it in its own settings.", scale: scale)

        Text("INSTALLED AGENTS")
            .font(.system(size: Theme.TextSize.micro * scale, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 18 * scale)
            .padding(.top, 18 * scale)
        ForEach(AgentProfiles.all) { profile in
            agentRow(profile, scale: scale)
        }
        settingsNote("Type any of these at a Balagan prompt — `codex`, `pi`, `opencode` — and the tab becomes an agent tab, with state, notifications and resume.", scale: scale)

        settingsRow("Custom agents", scale: scale) {
            Button("Open Agents Folder") {
                let directory = AgentProfiles.customDirectory()
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(URL(fileURLWithPath: directory))
            }
            .accessibilityIdentifier("open-agents-folder-button")
        }
        settingsNote("Add any agent as a JSON file there, e.g. {\"id\": \"goose\", \"resumeArguments\": [\"session\", \"resume\", \"--name\", \"{session}\"]}. Optional: command, displayName, sessionIDFlag, passthroughSubcommands. Takes effect after relaunching Balagan.", scale: scale)

        let hookLog = AgentHookLog.resolvePath()
        settingsRow("Agent hook log", scale: scale) {
            if let hookLog {
                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: hookLog)
                    if FileManager.default.fileExists(atPath: hookLog) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                }
                .accessibilityIdentifier("reveal-hook-log-button")
            } else {
                Text("Off").foregroundStyle(Theme.textTertiary)
            }
        }
        settingsNote(
            hookLog.map { "One line per agent hook event (never prompts or output) at \($0). Useful when an agent's state looks wrong." }
                ?? "Disabled by BALAGAN_HOOK_LOG=off.",
            scale: scale
        )
    }

    private func agentRow(_ profile: AgentProfile, scale: CGFloat) -> some View {
        let path = viewModel.installedAgents?[profile.id]
        let detecting = viewModel.installedAgents == nil
        return HStack(alignment: .top, spacing: 10 * scale) {
            Circle()
                .fill(path != nil ? Color(red: 0.25, green: 0.73, blue: 0.44) : Theme.textTertiary)
                .frame(width: 7 * scale, height: 7 * scale)
                .padding(.top, 5 * scale)
            VStack(alignment: .leading, spacing: 2 * scale) {
                HStack(spacing: 6 * scale) {
                    Text(profile.displayName)
                        .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(path ?? (detecting ? "checking…" : "not installed"))
                        .font(.system(size: Theme.TextSize.small * scale, design: path == nil ? .default : .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(profile.signalSummary)
                    .font(.system(size: Theme.TextSize.small * scale))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 5 * scale)
        .accessibilityIdentifier("agent-row-\(profile.id)")
    }

    // MARK: Notifications section

    @ViewBuilder
    private func notificationsSection(scale: CGFloat) -> some View {
        settingsRow("When an agent is waiting for you", scale: scale) {
            Toggle("", isOn: $waitingBanners).labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("waiting-banners-toggle")
        }
        settingsRow("When an agent finishes", scale: scale) {
            Toggle("", isOn: $finishedBanners).labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("finished-banners-toggle")
        }
        settingsNote("Banners only appear for agents you aren't looking at. The waiting and finished markers in the app always show.", scale: scale)

        settingsRow("macOS permission", scale: scale) {
            HStack(spacing: 8 * scale) {
                Text(notificationPermissionLabel)
                    .foregroundStyle(Theme.textSecondary)
                Button("Open Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                }
                .accessibilityIdentifier("open-notification-settings-button")
            }
        }
    }

    private var notificationPermissionLabel: String {
        switch SystemNotificationPresenter.shared.authorizationState {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .requested: return "Pending"
        case .notRequested: return "Dev build (no banners)"
        case .failed: return "Unavailable"
        }
    }

    /// A label on the left, a control on the right — the shape every settings row shares.
    private func settingsRow<Control: View>(_ label: String, scale: CGFloat, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(.system(size: Theme.TextSize.body * scale))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            control()
                .font(.system(size: Theme.TextSize.body * scale))
        }
        .padding(.horizontal, 18 * scale)
        .padding(.top, 10 * scale)
        .padding(.bottom, 2 * scale)
    }

    private func settingsNote(_ text: String, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: Theme.TextSize.micro * scale))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18 * scale)
    }

    /// "Sleep idle tasks after: 30 minutes". Sleeping frees a task's terminals; opening it resumes.
    @ViewBuilder
    private func autoSleepRow(scale: CGFloat) -> some View {
        HStack {
            Text("Sleep idle tasks after")
                .font(.system(size: 12 * scale))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker("", selection: Binding(
                get: { viewModel.autoSleepIdleMinutes },
                set: { viewModel.autoSleepIdleMinutes = $0 }
            )) {
                ForEach(AutoSleepPlanner.idleMinuteChoices, id: \.self) { minutes in
                    Text(Self.autoSleepLabel(minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("auto-sleep-picker")
        }
        .padding(.horizontal, 18 * scale)
        .padding(.top, 10 * scale)
        .padding(.bottom, 2 * scale)

        Text("Frees the memory of tasks whose agents are idle and whose shells aren't running anything. Opening a task wakes it and resumes its agent. Tasks also sleep sooner when macOS runs low on memory.")
            .font(.system(size: 10.5 * scale))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18 * scale)
    }

    static func autoSleepLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case let m where m % 60 == 0: return m == 60 ? "1 hour" : "\(m / 60) hours"
        default: return "\(minutes) minutes"
        }
    }

    private func contentHeader(_ title: String, scale: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 16 * scale, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18 * scale)
            .padding(.top, 18 * scale)
            .padding(.bottom, 8 * scale)
    }

    // MARK: Speech section

    /// Voice + rate for "Speak Last Response". Premium/enhanced voices only appear after the user
    /// downloads them in System Settings (no API to list or fetch them), hence the hint; Siri voices
    /// are never available to apps.
    @ViewBuilder
    private func speechSection(scale: CGFloat) -> some View {
        let voices = SpeechController.availableVoices()

        HStack {
            Text("Voice")
                .font(.system(size: 12 * scale))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker("", selection: Binding(
                get: { SpeechController.shared.voiceIdentifier ?? "" },
                set: { SpeechController.shared.voiceIdentifier = $0.isEmpty ? nil : $0 }
            )) {
                Text("Automatic (Best Voice)").tag("")
                Text("System Default").tag(SpeechController.systemDefaultVoiceChoice)
                Divider()
                ForEach(voices) { voice in
                    Text("\(voice.name) — \(voice.language)").tag(voice.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("speech-voice-picker")
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 4 * scale)

        HStack {
            Text("Rate")
                .font(.system(size: 12 * scale))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker("", selection: Binding(
                get: { SpeechController.shared.rateMultiplier },
                set: { SpeechController.shared.setRateMultiplier($0) }
            )) {
                ForEach(SpeechController.rateMultipliers, id: \.self) { multiplier in
                    Text(multiplier == multiplier.rounded()
                        ? "\(Int(multiplier))×"
                        : "\(String(format: "%.2g", multiplier))×").tag(multiplier)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("speech-rate-picker")
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 4 * scale)

        HStack(spacing: 6 * scale) {
            Text("Voices sound natural only after downloading a Premium/Enhanced one (Manage Voices → e.g. Ava Premium).")
                .font(.system(size: 10.5 * scale))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Settings…") {
                // Best-effort deep link to Accessibility → Spoken Content; falls back to Accessibility.
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
            .font(.system(size: 10.5 * scale))
            .accessibilityIdentifier("speech-open-system-settings")
        }
        .padding(.horizontal, 18 * scale)
        .padding(.top, 2 * scale)
    }

    // MARK: Keyboard shortcuts section

    @ViewBuilder
    private func shortcutsSection(scale: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Shortcuts")
                .font(.system(size: 16 * scale, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Reset All") {
                stopRecording()
                viewModel.resetAllShortcuts()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5 * scale, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .help("Restore every shortcut to its default")
            .accessibilityIdentifier("reset-all-shortcuts-button")
        }
        .padding(.horizontal, 18 * scale)
        .padding(.top, 18 * scale)
        .padding(.bottom, 4 * scale)

        Text(recordingAction == nil
            ? "Click a shortcut, then press the new key combination."
            : (recordError ?? "Press the new shortcut — or Esc to cancel."))
            .font(.system(size: 11 * scale))
            .foregroundStyle(recordError == nil ? Theme.textTertiary : .orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18 * scale)
            .padding(.bottom, 6 * scale)

        ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
            Text(group.rawValue.uppercased())
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18 * scale)
                .padding(.top, 12 * scale)
                .padding(.bottom, 2 * scale)

            ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                shortcutRow(action, scale: scale)
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: ShortcutAction, scale: CGFloat) -> some View {
        let chord = viewModel.keyboardShortcuts.chord(for: action)
        let isRecording = recordingAction == action
        let customized = viewModel.keyboardShortcuts.isCustomized(action)
        let conflict = viewModel.keyboardShortcuts.action(boundTo: chord, excluding: action)

        HStack(spacing: 8 * scale) {
            Text(action.displayName)
                .font(.system(size: 12.5 * scale))
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
                    .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(isRecording ? Color.accentColor : Theme.textPrimary)
                    .frame(minWidth: 74 * scale)
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 4 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 6 * scale)
                            .fill(isRecording ? Color.accentColor.opacity(0.12) : Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6 * scale)
                            .strokeBorder(isRecording ? Color.accentColor : Theme.hairline, lineWidth: 1)
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
        .padding(.horizontal, 16 * scale)
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

    private func applyTerminalFontZoom(_ action: String, _ appFontSize: Float) {
        TerminalHostRegistry.shared.performSharedFontZoomShortcut(
            action: action,
            evidenceName: "settings-font-zoom",
            appFontSize: appFontSize
        )
    }

    @ViewBuilder
    private func ghosttyInfoRow(scale: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10 * scale) {
            Image(systemName: "paintpalette")
                .font(.system(size: 12 * scale))
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 6 * scale) {
                Text("Theme, colors, and font family are inherited from your Ghostty config.")
                    .font(.system(size: 11.5 * scale))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = Self.ghosttyConfigURL() {
                    Button("Open config") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Reveal your Ghostty config in Finder")
                }
            }
        }
        .padding(.horizontal, 16 * scale)
        .padding(.top, 4 * scale)
    }

    private static func ghosttyConfigURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".config/ghostty/config"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

/// A label + segmented −/value/+ pill + quiet inline Reset. Shared by the UI-scale and terminal-font rows.
private struct SettingsStepperRow: View {
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

/// A monospace chip that copies its value to the clipboard on click, briefly flashing "Copied".
struct CopyableVarChip: View {
    let value: String
    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                Text(copied ? "Copied" : value)
                    .font(.system(.caption2, design: .monospaced))
            }
            .foregroundStyle(copied ? Color.accentColor : Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                    .fill(isHovered ? Theme.surfaceHover : Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                    .stroke(copied ? Color.accentColor.opacity(0.5) : Theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Copy \(value)")
    }
}
