import Foundation

/// One subscription rate-limit window (Claude's 5-hour / 7-day, Codex's primary / secondary).
public struct UsageWindow: Equatable, Sendable, Codable {
    /// Short name for the UI: "5h", "Week", or the window length ("2h", "3d").
    public var label: String
    /// 0–100 (can exceed 100 once a limit is blown).
    public var usedPercent: Double
    public var resetsAt: Date

    /// True when the window's reset time had passed at the last `current(at:)`: its count started
    /// over, and the agent hasn't reported since, so it reads 0% until it does.
    public var hasReset: Bool
    /// A full name when the label alone doesn't say it ("Fable weekly limit").
    public var title: String?
    /// When this window's number was reported, if older than the rest (a merged Claude reading).
    public var observedAt: Date?

    public init(
        label: String,
        usedPercent: Double,
        resetsAt: Date,
        hasReset: Bool = false,
        title: String? = nil,
        observedAt: Date? = nil
    ) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.hasReset = hasReset
        self.title = title
        self.observedAt = observedAt
    }

    /// Display order: the 5-hour window, then the week, then anything else.
    public var sortRank: Int {
        switch label {
        case "5h": return 0
        case "Week": return 1
        default: return 2
        }
    }

    /// The window's full name for tooltips and details.
    public var longLabel: String {
        if let title { return title }
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
    /// The subscription, when the agent says ("Max 5x · Team", "Plus").
    public var plan: String?
    /// Extra facts for the details view ("Extra usage off: out of credits").
    public var notes: [String]

    public init(agent: String, windows: [UsageWindow], observedAt: Date, plan: String? = nil, notes: [String] = []) {
        self.agent = agent
        self.windows = windows
        self.observedAt = observedAt
        self.plan = plan
        self.notes = notes
    }

    /// Combines two readings of the same agent: each window comes from whichever reading is newer
    /// (an older one is stamped with its own `observedAt`), plan and notes from whichever has them.
    public func merged(with other: AgentUsage) -> AgentUsage {
        let (newer, older) = observedAt >= other.observedAt ? (self, other) : (other, self)
        var windows = newer.windows
        for window in older.windows where windows.contains(where: { $0.label == window.label }) == false {
            var stamped = window
            stamped.observedAt = stamped.observedAt ?? older.observedAt
            windows.append(stamped)
        }
        return AgentUsage(
            agent: agent,
            windows: windows,
            observedAt: newer.observedAt,
            plan: newer.plan ?? older.plan,
            notes: newer.notes.isEmpty ? older.notes : newer.notes
        )
    }

    /// The usage as it stands at `now`, windows in display order. A window whose reset time has
    /// passed started over: it reads 0% (`hasReset`) until the agent reports again, rather than
    /// vanishing — an agent you haven't used since the reset really is at 0%.
    public func current(at now: Date) -> AgentUsage {
        let windows = windows
            .map { window -> UsageWindow in
                guard window.resetsAt <= now else { return window }
                var reset = window
                reset.usedPercent = 0
                reset.hasReset = true
                return reset
            }
            .sorted { ($0.sortRank, $0.label) < ($1.sortRank, $1.label) }
        return AgentUsage(agent: agent, windows: windows, observedAt: observedAt, plan: plan, notes: notes)
    }

    /// The busiest window, for a one-number summary.
    public var peakPercent: Double { windows.map(\.usedPercent).max() ?? 0 }

    /// The window closest to its limit (ties: the one resetting last, since it binds longer).
    public var tightestWindow: UsageWindow? {
        windows.max { ($0.usedPercent, $0.resetsAt) < ($1.usedPercent, $1.resetsAt) }
    }

    /// The next reset among windows that haven't reset yet.
    public func soonestReset(after now: Date) -> Date? {
        windows.filter { $0.hasReset == false && $0.resetsAt > now }.map(\.resetsAt).min()
    }
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
                let plan = (limits["plan_type"] as? String)?.nilIfBlank.map { $0.capitalized }
                var notes: [String] = []
                if let credits = limits["credits"] as? [String: Any] {
                    if credits["unlimited"] as? Bool == true {
                        notes.append("Credits: unlimited")
                    } else if credits["has_credits"] as? Bool == true, let balance = credits["balance"] {
                        notes.append("Credits: \(balance)")
                    } else {
                        notes.append("No extra credits")
                    }
                }
                return AgentUsage(agent: "codex", windows: windows, observedAt: observedAt, plan: plan, notes: notes)
            }
        }
        return nil
    }

    /// Claude's own cache of its usage page (`cachedUsageUtilization` in `~/.claude.json`, refreshed
    /// when Claude fetches it, e.g. for `/usage`): every limit, including model-scoped ones like the
    /// Fable weekly limit, plus extra-usage status. The account's plan comes from `oauthAccount`.
    public static func claudeCache(stateJSON data: Data) -> AgentUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any] else {
            return nil
        }
        let observedAt = number(cache["fetchedAtMs"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        var windows: [UsageWindow] = []
        for limit in utilization["limits"] as? [[String: Any]] ?? [] {
            guard let percent = number(limit["percent"]),
                  let resets = (limit["resets_at"] as? String).flatMap(parseTimestamp) else { continue }
            let kind = limit["kind"] as? String ?? ""
            let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            switch (kind, model) {
            case ("session", _):
                windows.append(UsageWindow(label: "5h", usedPercent: percent, resetsAt: resets))
            case ("weekly_all", _):
                windows.append(UsageWindow(label: "Week", usedPercent: percent, resetsAt: resets))
            case let (_, model?):
                windows.append(UsageWindow(label: model, usedPercent: percent, resetsAt: resets, title: "\(model) weekly limit"))
            default:
                let name = kind.replacingOccurrences(of: "_", with: " ").capitalized
                windows.append(UsageWindow(label: name, usedPercent: percent, resetsAt: resets, title: "\(name) limit"))
            }
        }
        if windows.isEmpty {
            // Older caches: only the per-window objects.
            for (key, label) in [("five_hour", "5h"), ("seven_day", "Week")] {
                guard let window = utilization[key] as? [String: Any],
                      let percent = number(window["utilization"]),
                      let resets = (window["resets_at"] as? String).flatMap(parseTimestamp) else { continue }
                windows.append(UsageWindow(label: label, usedPercent: percent, resetsAt: resets))
            }
        }
        guard windows.isEmpty == false else { return nil }
        var notes: [String] = []
        if let extra = utilization["extra_usage"] as? [String: Any] {
            if extra["is_enabled"] as? Bool == true {
                let used = number(extra["used_credits"]), limit = number(extra["monthly_limit"])
                notes.append(used.map { "Extra usage on: \($0)\(limit.map { " of \($0)" } ?? "") used this month" } ?? "Extra usage on")
            } else if let reason = (extra["disabled_reason"] as? String)?.nilIfBlank {
                notes.append("Extra usage off: \(reason.replacingOccurrences(of: "_", with: " "))")
            }
        }
        let plan = claudePlan(account: root["oauthAccount"] as? [String: Any])
        return AgentUsage(agent: "claude", windows: windows, observedAt: observedAt, plan: plan, notes: notes)
    }

    /// "Max 5x · Team" from the account's rate-limit tier and organization type.
    static func claudePlan(account: [String: Any]?) -> String? {
        guard let account else { return nil }
        let tier = (account["userRateLimitTier"] as? String ?? "").lowercased()
        var parts: [String] = []
        if tier.contains("max_20x") { parts.append("Max 20x") }
        else if tier.contains("max_5x") { parts.append("Max 5x") }
        else if tier.contains("max") { parts.append("Max") }
        else if tier.contains("pro") { parts.append("Pro") }
        switch account["organizationType"] as? String {
        case "claude_team": parts.append("Team")
        case "claude_enterprise": parts.append("Enterprise")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// ISO 8601, with or without fractional seconds. Claude writes microseconds
    /// ("…59.606369+00:00"), which ISO8601DateFormatter can't read, so the fraction is cut to millis.
    static func parseTimestamp(_ string: String) -> Date? {
        var text = string
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<end]
            text.replaceSubrange(text.index(after: dot)..<end, with: String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
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

    /// Claude's usage: the status line's live 5-hour / weekly numbers merged with Claude's own cache
    /// (the extra windows, plan and extra-usage status). The newer reading wins per window.
    public static func readClaude(
        root: String = defaultRoot,
        claudeState: String = claudeStateFile()
    ) -> AgentUsage? {
        let live = readClaudeStatusLine(root: root)
        let cached = FileManager.default.contents(atPath: claudeState).flatMap(AgentUsageParser.claudeCache(stateJSON:))
        switch (live, cached) {
        case let (live?, cached?): return live.merged(with: cached)
        case let (live?, nil): return live
        case let (nil, cached?): return cached
        default: return nil
        }
    }

    /// `~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json` when that's set.
    public static func claudeStateFile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let configDirectory = environment["CLAUDE_CONFIG_DIR"]?.nilIfBlank {
            return configDirectory + "/.claude.json"
        }
        return home + "/.claude.json"
    }

    static func readClaudeStatusLine(root: String = defaultRoot) -> AgentUsage? {
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
            parts.append(contentsOf: usage.windows.filter { $0.hasReset == false }.map { "\($0.label) \(Int($0.usedPercent.rounded()))%" })
        }
        return parts.joined(separator: " · ")
    }
}
