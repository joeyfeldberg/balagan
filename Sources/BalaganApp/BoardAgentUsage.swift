import AppKit
import BalaganCore
import SwiftUI

/// Subscription usage per agent (Claude's 5-hour / weekly limits, Codex's): read off-main from what
/// the agents themselves report (Claude → `balagan-agent statusline` → ~/.balagan/usage/claude.json;
/// Codex → its session rollouts), refreshed every minute and whenever an agent finishes a turn.
extension BoardViewModel {
    static let usageQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.agent-usage", qos: .utility)

    func refreshAgentUsage() {
        guard usageTrackingEnabled else { return }
        Self.usageQueue.async { [weak self] in
            let now = Date()
            let usage = [AgentUsageStore.readClaude(), AgentUsageStore.readCodex()]
                .compactMap { $0?.current(at: now) }
            DispatchQueue.main.async {
                guard let self, self.agentUsage != usage else { return }
                self.agentUsage = usage
            }
        }
    }

    /// `BALAGAN_FIXTURE_USAGE=1`: sample numbers for a headless snapshot.
    func seedUsageForSnapshot() {
        let now = Date()
        agentUsage = [
            AgentUsage(agent: "claude", windows: [
                UsageWindow(label: "5h", usedPercent: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                UsageWindow(label: "Week", usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 86400)),
            ], observedAt: now),
            AgentUsage(agent: "codex", windows: [
                UsageWindow(label: "5h", usedPercent: 24, resetsAt: now.addingTimeInterval(4 * 3600)),
                UsageWindow(label: "Week", usedPercent: 88, resetsAt: now.addingTimeInterval(5 * 86400)),
            ], observedAt: now),
        ]
    }
}

extension BalaganApplication {
    /// Re-reads agent usage every minute (not in `--ui-test-mode`: it reads real agent files).
    @MainActor
    func startUsagePolling() {
        viewModel?.refreshAgentUsage()
        usagePollTimer?.invalidate()
        usagePollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel?.refreshAgentUsage()
            }
        }
        watchClaudeUsageFile()
    }

    /// Claude's status line rewrites `usage/claude.json` (an atomic rename) on every refresh. Watching
    /// the folder puts a new number in the sidebar right away instead of on the next minute tick.
    /// The fd is closed only by the cancel handler, and the watcher is never torn down on quit (see
    /// the DispatchSource gotcha in AGENTS.md).
    @MainActor
    private func watchClaudeUsageFile() {
        guard usageWatcher == nil else { return }
        let directory = (AgentUsageStore.claudeFile() as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.viewModel?.refreshAgentUsage()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        usageWatcher = source
    }
}

/// The sidebar's usage meter: one row per agent, a thin bar per limit window. Hover for exact numbers
/// and reset times.
struct SidebarUsageMeter: View {
    let usage: [AgentUsage]
    @Environment(\.balaganUIScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(usage, id: \.agent) { agent in
                HStack(spacing: 10 * scale) {
                    Text(Self.displayName(agent.agent))
                        .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(width: 44 * scale, alignment: .leading)
                    ForEach(agent.windows, id: \.label) { window in
                        UsageWindowBar(window: window)
                    }
                }
                .help(Self.tooltip(agent))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("usage-\(agent.agent)")
            }
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 9 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func displayName(_ agent: String) -> String {
        AgentProfiles.named(agent)?.displayName.replacingOccurrences(of: " Code", with: "") ?? agent.capitalized
    }

    static func tooltip(_ agent: AgentUsage) -> String {
        let lines = agent.windows.map { window in
            "\(window.longLabel): \(Int(window.usedPercent.rounded()))% used, resets \(resetPhrase(window.resetsAt))"
        }
        return ([displayName(agent.agent)] + lines).joined(separator: "\n")
    }

    static func resetPhrase(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(max(minutes, 1))m"
    }
}

private struct UsageWindowBar: View {
    let window: UsageWindow
    @Environment(\.balaganUIScale) private var scale

    private var fraction: Double { min(max(window.usedPercent / 100, 0), 1) }
    private var tint: Color {
        switch window.usedPercent {
        case 95...: return Color(nsColor: .systemRed)
        case 80..<95: return Color(nsColor: .systemOrange)
        default: return Theme.accent
        }
    }

    var body: some View {
        HStack(spacing: 4 * scale) {
            // "Week" doesn't fit beside two bars in the sidebar; the tooltip spells it out.
            Text(window.label == "Week" ? "Wk" : window.label)
                .font(.system(size: Theme.TextSize.micro * scale))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(tint).frame(width: 24 * scale * fraction)
            }
            .frame(width: 24 * scale, height: 4 * scale)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: Theme.TextSize.micro * scale).monospacedDigit())
                .foregroundStyle(window.usedPercent >= 80 ? tint : Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
