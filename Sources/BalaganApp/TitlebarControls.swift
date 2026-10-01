import SwiftUI
import BalaganCore

/// Window-titlebar controls (next to the traffic lights), cmux-style: a hide-sidebar toggle and a
/// notification bell. The bell badges the count of terminals where an agent finished while you weren't
/// looking, and its menu jumps you to any of them (selecting that tab clears its highlight).
struct TitlebarControls: View {
    @ObservedObject var viewModel: BoardViewModel

    var body: some View {
        let targets = viewModel.attentionTargets()
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { viewModel.isSidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(viewModel.isSidebarVisible ? "Hide sidebar" : "Show sidebar")

            // One menu, two badges: green = working, amber = blocked on you. Both counts are derived
            // from `activeAgentSessions()`, the same list the rows come from, so a badge can never
            // disagree with what opening the menu shows.
            let sessions = viewModel.activeAgentSessions()
            let waiting = sessions.filter { $0.lifecycle == .needsInput }
            let running = sessions.filter { $0.lifecycle == .running }
            BadgedMenu(
                systemImage: "sparkles",
                count: running.count,
                badgeColor: TaskStatus.done.color,
                secondaryCount: waiting.count,
                secondaryBadgeColor: Theme.agentWaiting,
                help: "Agents — jump to one that's working or waiting"
            ) {
                if sessions.isEmpty {
                    Text("No agents running")
                } else {
                    // Waiting first: a blocked agent is the one costing you time.
                    if waiting.isEmpty == false {
                        Section("Waiting for you") {
                            ForEach(waiting) { session in
                                sessionButton(session)
                            }
                        }
                    }
                    if running.isEmpty == false {
                        Section("Running agents") {
                            ForEach(running) { session in
                                sessionButton(session)
                            }
                        }
                    }
                }
            }

            BadgedMenu(
                systemImage: targets.isEmpty ? "bell" : "bell.fill",
                count: targets.count,
                badgeColor: Color.accentColor,
                help: "Notifications — jump to an updated terminal"
            ) {
                if targets.isEmpty {
                    Text("No new activity")
                } else {
                    Section("Updated terminals") {
                        ForEach(targets) { target in
                            Button {
                                viewModel.jumpToAttention(target)
                            } label: {
                                Text("\(target.title) · \(target.detail)")
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
    }

    private func sessionButton(_ session: AgentSessionItem) -> some View {
        Button {
            viewModel.jumpToSession(session)
        } label: {
            Label(
                "\(session.taskTitle) · \(session.surfaceTitle)",
                systemImage: agentSessionIcon(session.lifecycle)
            )
        }
    }

    private func agentSessionIcon(_ lifecycle: AgentLifecycle?) -> String {
        switch lifecycle {
        case .running: return "play.circle.fill"
        case .needsInput: return "questionmark.circle.fill"   // same glyph the card/sidebar/tab use
        case .idle: return "pause.circle"
        case nil: return "terminal"
        }
    }
}
