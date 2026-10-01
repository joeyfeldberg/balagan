import AppKit
import SwiftUI
import BalaganCore

struct EmptyTerminalWorkspace: View {
    let task: TaskItem
    let onAddSurface: () -> Void
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        VStack(spacing: 14 * balaganUIScale) {
            Image(systemName: "terminal")
                .font(.system(size: 30 * balaganUIScale, weight: .light))
                .foregroundStyle(Theme.textTertiary)

            VStack(spacing: 4 * balaganUIScale) {
                Text("No terminal tabs")
                    .font(.system(size: 14 * balaganUIScale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Create a terminal for \(task.title) to run commands in this task workspace.")
                    .font(.system(size: 12 * balaganUIScale))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360 * balaganUIScale)
            }

            Button {
                onAddSurface()
            } label: {
                Label("New Terminal Tab", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.borderedProminent)
            .font(.system(size: 13 * balaganUIScale))
            .accessibilityIdentifier("create-terminal-tab-button")
        }
        .padding(28 * balaganUIScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgWindow)
        .accessibilityIdentifier("empty-terminal-workspace")
    }
}

struct TerminalPane: View {
    let taskID: TaskItem.ID
    let surface: Surface
    var isActive = true
    let shortcuts: TerminalShortcutContext
    var onActivate: () -> Void = {}
    var onEndedProcessSurface: (TaskItem.ID, Surface.ID) -> Void = { _, _ in }
    @Environment(\.artifactDirectory) private var artifactDirectory
    @Environment(\.terminalRuntime) private var terminalRuntime
    @Environment(\.terminalAppearance) private var terminalAppearance
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        ZStack(alignment: .topTrailing) {
            terminalContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))

            if let resumePlan = surface.resumeAffordancePlan(
                taskID: taskID,
                processPreference: terminalRuntime.processPreference
            ) {
                Button("Resume") {
                    ResumeRequestRecorder.record(plan: resumePlan, artifactDirectory: artifactDirectory)
                    if terminalRuntime.selection.kind == .libghostty,
                       let command = surface.confirmedResumeCommand(taskID: taskID) {
                        TerminalHostRegistry.shared.resume(
                            TerminalSessionConfig(
                                taskID: taskID,
                                surface: surface,
                                runtime: terminalRuntime,
                                terminalAppearance: terminalAppearance,
                                artifactDirectory: artifactDirectory
                            ),
                            command: command
                        )
                    }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 13 * balaganUIScale))
                .padding(10 * balaganUIScale)
                .accessibilityIdentifier("resume-button-\(surface.id)")
                .help(resumePlan.displayCommand)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var terminalContent: some View {
        switch terminalRuntime.selection.kind {
        case .libghostty:
            LibGhosttyTerminalView(
                taskID: taskID,
                surface: surface,
                runtime: terminalRuntime,
                terminalAppearance: terminalAppearance,
                artifactDirectory: artifactDirectory,
                isActive: isActive,
                shortcuts: shortcuts,
                onActivate: onActivate,
                onEndedProcessSurface: onEndedProcessSurface
            )
                .id("libghostty-\(taskID)-\(surface.id)")
                .accessibilityIdentifier("libghostty-terminal-\(surface.id)")
        case .fixture:
            FakeTerminalScrollback(surface: surface)
        case .unavailable:
            VStack(alignment: .leading, spacing: 10) {
                TerminalUnavailableBanner(selection: terminalRuntime.selection)
                FakeTerminalScrollback(surface: surface)
            }
        }
    }
}

private struct FakeTerminalScrollback: View {
    let surface: Surface
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4 * balaganUIScale) {
                ForEach(Array(surface.output.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 13 * balaganUIScale, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12 * balaganUIScale)
        }
    }
}

private struct TerminalUnavailableBanner: View {
    let selection: TerminalBackendSelection
    @Environment(\.balaganUIScale) private var balaganUIScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * balaganUIScale) {
            Text("libghostty unavailable")
                .font(.system(size: 12 * balaganUIScale, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(selection.libGhostty.diagnostic ?? selection.reason)
                .font(.system(size: 12 * balaganUIScale, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(10 * balaganUIScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
