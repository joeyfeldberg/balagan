import Foundation

/// One subscription rate-limit window (Claude's 5-hour / 7-day, Codex's primary / secondary).
public struct UsageWindow: Equatable, Sendable, Codable {
    /// Short name for the UI: "5h", "Week", or the window length ("2h", "3d").
    public var label: String
    /// 0–100 (can exceed 100 once a limit is blown).
    public var usedPercent: Double
    public var resetsAt: Date

    public init(label: String, usedPercent: Double, resetsAt: Date) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// The window's full name for tooltips.
    public var longLabel: String {
        switch label {
        case "5h": return "5-hour limit"
        case "Week": return "Weekly limit"
        default: return "\(label) limit"
        }
    }
}

/// How much of an agent's subscription quota is used, as last reported by the agent itself.
public struct AgentUsage: Equatable, Sendable, Codable {
    /// The agent profile id: "claude" or "codex".
    public var agent: String
    public var windows: [UsageWindow]
    /// When the agent reported these numbers.
    public var observedAt: Date

    public init(agent: String, windows: [UsageWindow], observedAt: Date) {
        self.agent = agent
        self.windows = windows
        self.observedAt = observedAt
    }

    /// The windows still in force at `now`. One whose reset time has passed is dropped (its count
    /// started over, and we haven't heard the new number yet), as Claude Code itself does.
    public func current(at now: Date) -> AgentUsage? {
        let live = windows.filter { $0.resetsAt > now }
        return live.isEmpty ? nil : AgentUsage(agent: agent, windows: live, observedAt: observedAt)
    }

    /// The busiest window, for a one-number summary.
    public var peakPercent: Double { windows.map(\.usedPercent).max() ?? 0 }
}

public enum AgentUsageParser {
    /// Claude Code passes `rate_limits` to the status line command on every refresh (claude.ai Pro/Max
    /// only, after the session's first response): `five_hour` / `seven_day`, each with
    /// `used_percentage` and `resets_at` (epoch seconds).
    public static func claude(statusLineJSON data: Data, observedAt: Date) -> AgentUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else {
            return nil
        }
        return claude(rateLimits: limits, observedAt: observedAt)
    }

    public static func claude(rateLimits limits: [String: Any], observedAt: Date) -> AgentUsage? {
        var windows: [UsageWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "Week")] {
            guard let window = limits[key] as? [String: Any],
                  let used = number(window["used_percentage"]),
                  let resets = number(window["resets_at"]) else { continue }
            windows.append(UsageWindow(label: label, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets)))
        }
        return windows.isEmpty ? nil : AgentUsage(agent: "claude", windows: windows, observedAt: observedAt)
    }

    /// Codex logs `rate_limits` with each `token_count` event in its session rollout:
    /// `primary` / `secondary`, each with `used_percent`, `window_minutes`, and `resets_at` (epoch
    /// seconds; older builds wrote `resets_in_seconds`, relative to the line's `timestamp`). Takes the
    /// rollout's text (a tail is enough) and returns the newest report in it.
    public static func codex(rolloutText text: String) -> AgentUsage? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let observedAt = (object["timestamp"] as? String).flatMap(parseTimestamp) ?? Date()
            var windows: [UsageWindow] = []
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any],
                      let used = number(window["used_percent"]) else { continue }
                let resetsAt: Date
                if let resets = number(window["resets_at"]) {
                    resetsAt = Date(timeIntervalSince1970: resets)
                } else if let seconds = number(window["resets_in_seconds"]) {
                    resetsAt = observedAt.addingTimeInterval(seconds)
                } else {
                    continue
                }
                let minutes = number(window["window_minutes"]).map(Int.init)
                windows.append(UsageWindow(
                    label: minutes.map(windowLabel(minutes:)) ?? (key == "primary" ? "5h" : "Week"),
                    usedPercent: used,
                    resetsAt: resetsAt
                ))
            }
            if windows.isEmpty == false {
                return AgentUsage(agent: "codex", windows: windows, observedAt: observedAt)
            }
        }
        return nil
    }

    public static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: return "5h"
        case 10_080: return "Week"
        case let m where m % 1440 == 0: return "\(m / 1440)d"
        case let m where m % 60 == 0: return "\(m / 60)h"
        default: return "\(minutes)m"
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Where agent usage lives on disk, and how to read the newest report.
public enum AgentUsageStore {
    /// Balagan's data folder: `$BALAGAN_HOME`, else `~/.balagan` (the same override the wrapper's
    /// integration files honour).
    public static var defaultRoot: String {
        ProcessInfo.processInfo.environment["BALAGAN_HOME"]?.nilIfBlank ?? (NSHomeDirectory() + "/.balagan")
    }

    /// `<root>/usage/claude.json`: the `rate_limits` from Claude's last status-line refresh, written by
    /// `balagan-agent statusline` (Claude has no other place that records them).
    public static func claudeFile(root: String = defaultRoot) -> String {
        root + "/usage/claude.json"
    }

    public static func writeClaude(rateLimits: [String: Any], observedAt: Date, root: String = defaultRoot) throws {
        let path = claudeFile(root: root)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let object: [String: Any] = ["observedAt": observedAt.timeIntervalSince1970, "rate_limits": rateLimits]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func readClaude(root: String = defaultRoot) -> AgentUsage? {
        guard let data = FileManager.default.contents(atPath: claudeFile(root: root)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else {
            return nil
        }
        let observedAt = (object["observedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        return AgentUsageParser.claude(rateLimits: limits, observedAt: observedAt)
    }

    /// The newest Codex session that reported limits: walks `$CODEX_HOME/sessions` newest-first and
    /// reads the tail of each rollout until one has a `rate_limits` line (a session that hasn't had a
    /// response yet has none).
    public static func readCodex(
        codexHome: String = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex"),
        maxFiles: Int = 8,
        tailBytes: Int = 256 * 1024
    ) -> AgentUsage? {
        let sessions = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
        // Rollouts live in sessions/YYYY/MM/DD/; walk the newest day folders only, so months of
        // history never get listed.
        let fileManager = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var rollouts: [(URL, Date)] = []
        outer: for year in children(sessions) {
            for month in children(year) {
                for day in children(month) {
                    for file in children(day) where file.pathExtension == "jsonl" {
                        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        rollouts.append((file, modified ?? .distantPast))
                    }
                    if rollouts.count >= maxFiles { break outer }
                }
            }
        }
        for (url, _) in rollouts.sorted(by: { $0.1 > $1.1 }).prefix(maxFiles) {
            if let usage = AgentUsageParser.codex(rolloutText: tail(of: url, bytes: tailBytes)) {
                return usage
            }
        }
        return nil
    }

    static func tail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Claude Code allows one status line. Inside Balagan the wrapper installs its own
/// (`balagan-agent statusline`) to capture `rate_limits`, then runs the user's — found here — so
/// their status line looks exactly as before.
public enum ClaudeStatusLine {
    /// The user's own `statusLine` setting, by Claude's precedence: the project's
    /// `.claude/settings.local.json`, then `.claude/settings.json`, then the user settings in
    /// `$CLAUDE_CONFIG_DIR` (default `~/.claude`). Ours is skipped, so it can never run itself.
    public static func userSetting(
        projectDirectory: String?,
        home: String = NSHomeDirectory(),
        configDirectory: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    ) -> [String: Any]? {
        var files: [String] = []
        if let projectDirectory = projectDirectory?.nilIfBlank {
            files.append(projectDirectory + "/.claude/settings.local.json")
            files.append(projectDirectory + "/.claude/settings.json")
        }
        files.append((configDirectory?.nilIfBlank ?? (home + "/.claude")) + "/settings.json")
        for file in files {
            guard let data = FileManager.default.contents(atPath: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statusLine = object["statusLine"] as? [String: Any],
                  let command = (statusLine["command"] as? String)?.nilIfBlank,
                  isOurs(command) == false else { continue }
            return statusLine
        }
        return nil
    }

    public static func isOurs(_ command: String) -> Bool {
        command.contains("balagan-agent") && command.contains("statusline")
    }

    /// What we print when the user has no status line of their own: model, context, and the limits.
    public static func defaultLine(statusLineJSON data: Data, now: Date = Date()) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        var parts: [String] = []
        if let model = (object["model"] as? [String: Any])?["display_name"] as? String {
            parts.append(model)
        }
        if let context = ((object["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue {
            parts.append("ctx \(Int(context.rounded()))%")
        }
        if let usage = AgentUsageParser.claude(statusLineJSON: data, observedAt: now)?.current(at: now) {
            parts.append(contentsOf: usage.windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))%" })
        }
        return parts.joined(separator: " · ")
    }
}
