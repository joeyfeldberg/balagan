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
                UsageWindow(label: "Fable", usedPercent: 33, resetsAt: now.addingTimeInterval(3 * 86400), title: "Fable weekly limit"),
            ], observedAt: now, plan: "Max 5x", notes: ["Extra usage off: out of credits"]),
            AgentUsage(agent: "codex", windows: [
                UsageWindow(label: "5h", usedPercent: 24, resetsAt: now.addingTimeInterval(4 * 3600)),
                UsageWindow(label: "Week", usedPercent: 88, resetsAt: now.addingTimeInterval(5 * 86400)),
            ], observedAt: now, plan: "Plus", notes: ["No extra credits"]),
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

/// The sidebar's usage meter: one row per agent, the 5-hour and weekly windows always in the same
/// columns (Compact shows only each agent's tightest window). Each row is a button: click it for that
/// agent's full details (`AgentUsageDetails`).
struct SidebarUsageMeter: View {
    let usage: [AgentUsage]
    var onRefresh: () -> Void = {}
    @Environment(\.balaganUIScale) private var scale

    /// The columns every row lines up on, in order. Other windows (Claude's Fable weekly limit, …)
    /// only appear in the details.
    static let slots = ["5h", "Week"]

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            ForEach(usage, id: \.agent) { agent in
                UsageMeterRow(agent: agent, onRefresh: onRefresh)
            }
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 6 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("usage-meter")
    }

    static func displayName(_ agent: String) -> String {
        AgentProfiles.named(agent)?.displayName.replacingOccurrences(of: " Code", with: "") ?? agent.capitalized
    }

    static func tooltip(_ agent: AgentUsage) -> String {
        let lines = agent.windows.map { window in
            "\(window.longLabel): \(Int(window.usedPercent.rounded()))% used, \(resetDescription(window))"
        }
        return ([displayName(agent.agent)] + lines + ["Click for details"]).joined(separator: "\n")
    }

    static func resetDescription(_ window: UsageWindow, now: Date = Date()) -> String {
        window.hasReset ? "reset, no reading since" : "resets \(resetPhrase(window.resetsAt, now: now))"
    }

    static func resetPhrase(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(max(minutes, 1))m"
    }

    /// "today 21:40", "tomorrow 09:00", or "Thu 14:00".
    static func clockPhrase(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func agoPhrase(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    /// Where each agent shows its usage on the web.
    static func usagePage(_ agent: String) -> URL? {
        switch agent {
        case "claude": return URL(string: "https://claude.ai/settings/usage")
        case "codex": return URL(string: "https://chatgpt.com/codex/settings/usage")
        default: return nil
        }
    }
}

/// One agent's row in the meter, and the popover it opens.
private struct UsageMeterRow: View {
    let agent: AgentUsage
    let onRefresh: () -> Void
    @AppStorage(AppPreferences.Keys.usageCompact) private var compact = false
    // `BALAGAN_SHOW_USAGE_DETAILS=<agent>` opens that agent's details at launch, for a screenshot.
    @State private var showingDetails: Bool
    @State private var hovering = false
    @Environment(\.balaganUIScale) private var scale

    init(agent: AgentUsage, onRefresh: @escaping () -> Void) {
        self.agent = agent
        self.onRefresh = onRefresh
        _showingDetails = State(initialValue: ProcessInfo.processInfo.environment["BALAGAN_SHOW_USAGE_DETAILS"] == agent.agent)
    }

    var body: some View {
        Button {
            showingDetails.toggle()
        } label: {
            HStack(spacing: 10 * scale) {
                Text(SidebarUsageMeter.displayName(agent.agent))
                    .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 44 * scale, alignment: .leading)
                if compact {
                    if let tightest = agent.tightestWindow { UsageWindowBar(window: tightest) }
                } else {
                    ForEach(SidebarUsageMeter.slots, id: \.self) { slot in
                        if let window = agent.windows.first(where: { $0.label == slot }) {
                            UsageWindowBar(window: window)
                        } else {
                            UsageWindowBar(window: UsageWindow(label: slot, usedPercent: 0, resetsAt: .distantFuture)).hidden()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                RoundedRectangle(cornerRadius: 5 * scale)
                    .fill(hovering || showingDetails ? Theme.hairline : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(SidebarUsageMeter.tooltip(agent))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-\(agent.agent)")
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            AgentUsageDetails(agent: agent, onRefresh: onRefresh)
        }
    }
}

/// Everything one agent reports about its quota: plan, every limit window (including model-scoped
/// ones like Claude's Fable weekly limit) with its exact reset time, extra usage / credits, when it
/// last reported, and a link to the agent's own usage page.
private struct AgentUsageDetails: View {
    let agent: AgentUsage
    let onRefresh: () -> Void
    @AppStorage(AppPreferences.Keys.usageCompact) private var compact = false

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SidebarUsageMeter.displayName(agent.agent))
                    .font(.system(size: Theme.TextSize.heading, weight: .semibold))
                if let plan = agent.plan {
                    Text(plan)
                        .font(.system(size: Theme.TextSize.micro, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.hairlineStrong))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Re-read the usage now")
                    .accessibilityIdentifier("usage-refresh")
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(agent.windows, id: \.label) { window in
                    windowRow(window, now: now)
                }
            }

            if agent.notes.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(agent.notes, id: \.self) { note in
                        Text(note)
                            .font(.system(size: Theme.TextSize.small))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text("Updated \(SidebarUsageMeter.agoPhrase(agent.observedAt, now: now))")
                    .font(.system(size: Theme.TextSize.micro))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if let page = SidebarUsageMeter.usagePage(agent.agent) {
                    Link("Usage page", destination: page)
                        .font(.system(size: Theme.TextSize.small))
                }
            }
            HStack {
                Text("Sidebar").font(.system(size: Theme.TextSize.small)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("Sidebar", selection: $compact) {
                    Text("Detailed").tag(false)
                    Text("Compact").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Compact shows only each agent's tightest limit")
            }
        }
        .padding(16)
        .frame(width: 320)
        .accessibilityIdentifier("usage-details-\(agent.agent)")
    }

    private func windowRow(_ window: UsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.longLabel)
                    .font(.system(size: Theme.TextSize.body, weight: .medium))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: Theme.TextSize.body).monospacedDigit())
                    .foregroundStyle(window.usedPercent >= 80 ? UsageWindowBar.tint(for: window.usedPercent) : Theme.textPrimary)
            }
            UsageBarShape(fraction: window.usedPercent / 100, tint: UsageWindowBar.tint(for: window.usedPercent))
                .frame(height: 6)
                .opacity(window.hasReset ? 0.5 : 1)
            Text(detailLine(window, now: now))
                .font(.system(size: Theme.TextSize.micro))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailLine(_ window: UsageWindow, now: Date) -> String {
        var parts: [String] = []
        let stale = window.observedAt.map { now.timeIntervalSince($0) > 600 } ?? false
        if window.hasReset {
            parts.append("Reset \(SidebarUsageMeter.clockPhrase(window.resetsAt, now: now))")
            parts.append(stale && agent.agent == "claude" ? "run /usage in Claude for a new reading" : "no reading since")
        } else {
            parts.append("Resets \(SidebarUsageMeter.resetPhrase(window.resetsAt, now: now)) · \(SidebarUsageMeter.clockPhrase(window.resetsAt, now: now))")
            if stale, let asOf = window.observedAt {
                parts.append("as of \(SidebarUsageMeter.agoPhrase(asOf, now: now))")
            }
        }
        return parts.joined(separator: " · ")
    }
}

private struct UsageBarShape: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

private struct UsageWindowBar: View {
    let window: UsageWindow
    @Environment(\.balaganUIScale) private var scale

    static func tint(for percent: Double) -> Color {
        switch percent {
        case 95...: return Color(nsColor: .systemRed)
        case 80..<95: return Color(nsColor: .systemOrange)
        default: return Theme.accent
        }
    }

    var body: some View {
        let tint = Self.tint(for: window.usedPercent)
        HStack(spacing: 4 * scale) {
            // "Week" doesn't fit beside two bars in the sidebar; the tooltip spells it out.
            Text(window.label == "Week" ? "Wk" : window.label)
                .font(.system(size: Theme.TextSize.micro * scale))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(width: 18 * scale, alignment: .leading)
            UsageBarShape(fraction: window.usedPercent / 100, tint: tint)
                .frame(width: 24 * scale, height: 4 * scale)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: Theme.TextSize.micro * scale).monospacedDigit())
                .foregroundStyle(window.usedPercent >= 80 ? tint : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 30 * scale, alignment: .trailing)
        }
        .opacity(window.hasReset ? 0.55 : 1)
    }
}
