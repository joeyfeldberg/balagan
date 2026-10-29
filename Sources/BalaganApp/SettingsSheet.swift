import AppKit
import SwiftUI
import BalaganCore

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case agents = "Agents"
    case notifications = "Notifications"
    case prompts = "Prompts"
    case terminal = "Terminal"
    case speech = "Speech"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .agents: return "sparkles"
        case .notifications: return "bell.badge"
        case .prompts: return "text.bubble"
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
    @State private var selectedCategory: SettingsCategory = SettingsSheet.lastCategory
    /// The page last shown, so a theme change (which rebuilds this view) stays on the same page.
    @MainActor static var lastCategory: SettingsCategory =
        SettingsCategory(rawValue: ProcessInfo.processInfo.environment["BALAGAN_SETTINGS_CATEGORY"] ?? "") ?? .general
    @AppStorage(AppPreferences.Keys.defaultAgent) private var defaultAgentRaw = AppPreferences.defaultAgent.rawValue
    @AppStorage(AppPreferences.Keys.waitingBanners) private var waitingBanners = true
    @AppStorage(AppPreferences.Keys.finishedBanners) private var finishedBanners = true
    @AppStorage(AppPreferences.Keys.menuBarItem) private var showMenuBarItem = true

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
        .onChange(of: selectedCategory) { _, category in
            SettingsSheet.lastCategory = category
        }
        .onAppear {
            if presentationScale == nil {
                presentationScale = balaganUIScale
            }
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
                            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                        Text(category.rawValue)
                            .font(.system(size: Theme.TextSize.title * scale, weight: selected ? .semibold : .regular))
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
            settingsRow("Show agents in the menu bar", scale: scale) {
                Toggle("", isOn: $showMenuBarItem).labelsHidden().toggleStyle(.switch)
                    .accessibilityIdentifier("menu-bar-item-toggle")
            }
        case .appearance:
            contentHeader("Appearance", scale: scale)
            settingsRow("Use the theme's colors in terminals", scale: scale) {
                Toggle("", isOn: Binding(
                    get: { AppPreferences.themeTerminals },
                    set: { viewModel.setThemeTerminals($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("theme-terminals-toggle")
            }
            ThemePicker(selectedID: viewModel.appThemeID, scale: scale) { viewModel.selectAppTheme($0) }
                .padding(.horizontal, SettingsLayout.inset * scale)
                .padding(.bottom, 18 * scale)
        case .agents:
            contentHeader("Agents", scale: scale)
            agentsSection(scale: scale)
        case .notifications:
            contentHeader("Notifications", scale: scale)
            notificationsSection(scale: scale)
        case .prompts:
            contentHeader("Prompts", scale: scale)
            GlobalPromptsPage()
                .padding(.horizontal, SettingsLayout.inset * scale)
                .padding(.bottom, 18 * scale)
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
            ShortcutsSettingsPage(viewModel: viewModel, scale: scale)
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
            .padding(.horizontal, SettingsLayout.inset * scale)
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
                .fill(path != nil ? Theme.positive : Theme.textTertiary)
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
        .padding(.horizontal, SettingsLayout.inset * scale)
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
        .padding(.horizontal, SettingsLayout.inset * scale)
        .padding(.top, 10 * scale)
        .padding(.bottom, 2 * scale)
    }

    private func settingsNote(_ text: String, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: Theme.TextSize.micro * scale))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsLayout.inset * scale)
    }

    /// "Sleep idle tasks after: 30 minutes". Sleeping frees a task's terminals; opening it resumes.
    @ViewBuilder
    private func autoSleepRow(scale: CGFloat) -> some View {
        settingsRow("Sleep idle tasks after", scale: scale) {
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
        settingsNote("Frees the memory of tasks whose agents are idle and whose shells aren't running anything. Opening a task wakes it and resumes its agent. Tasks also sleep sooner when macOS runs low on memory.", scale: scale)
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
            .font(.system(size: Theme.TextSize.heading * scale, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, SettingsLayout.inset * scale)
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

        settingsRow("Voice", scale: scale) {
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
        settingsRow("Rate", scale: scale) {
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

        HStack(spacing: 6 * scale) {
            Text("Voices sound natural only after downloading a Premium/Enhanced one (Manage Voices → e.g. Ava Premium).")
                .font(.system(size: Theme.TextSize.micro * scale))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Settings…") {
                // Best-effort deep link to Accessibility → Spoken Content; falls back to Accessibility.
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
            .font(.system(size: Theme.TextSize.micro * scale))
            .accessibilityIdentifier("speech-open-system-settings")
        }
        .padding(.horizontal, SettingsLayout.inset * scale)
        .padding(.top, 2 * scale)
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
                    .font(.system(size: Theme.TextSize.small * scale))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = Self.ghosttyConfigURL() {
                    Button("Open config") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .help("Reveal your Ghostty config in Finder")
                }
            }
        }
        .padding(.horizontal, SettingsLayout.inset * scale)
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
