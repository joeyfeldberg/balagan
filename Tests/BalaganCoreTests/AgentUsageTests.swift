import XCTest
@testable import BalaganCore

final class AgentUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Claude (status line input)

    func testParsesClaudeRateLimitsFromTheStatusLineInput() throws {
        let json = #"""
        {"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1790003600},
         "seven_day":{"used_percentage":41.2,"resets_at":1790300000}}}
        """#
        let usage = try XCTUnwrap(AgentUsageParser.claude(statusLineJSON: Data(json.utf8), observedAt: now))
        XCTAssertEqual(usage.agent, "claude")
        XCTAssertEqual(usage.windows, [
            UsageWindow(label: "5h", usedPercent: 23.5, resetsAt: Date(timeIntervalSince1970: 1_790_003_600)),
            UsageWindow(label: "Week", usedPercent: 41.2, resetsAt: Date(timeIntervalSince1970: 1_790_300_000)),
        ])
        XCTAssertEqual(usage.peakPercent, 41.2)
    }

    func testClaudeWithoutRateLimitsReportsNothing() {
        // API-key users, and every session before its first response.
        XCTAssertNil(AgentUsageParser.claude(statusLineJSON: Data(#"{"model":{}}"#.utf8), observedAt: now))
    }

    // MARK: Codex (session rollout)

    func testTakesTheNewestCodexReportInARollout() throws {
        let rollout = [
            #"{"timestamp":"2026-10-05T20:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1790010000},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":1790500000}}}}"#,
            #"{"timestamp":"2026-10-05T20:05:00.000Z","type":"response_item","payload":{"type":"message"}}"#,
            #"{"timestamp":"2026-10-05T20:10:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":24.0,"window_minutes":300,"resets_at":1790010000},"secondary":{"used_percent":14.0,"window_minutes":10080,"resets_at":1790500000}}}}"#,
        ].joined(separator: "\n")
        let usage = try XCTUnwrap(AgentUsageParser.codex(rolloutText: rollout))
        XCTAssertEqual(usage.agent, "codex")
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "Week"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [24, 14])
    }

    func testOlderCodexBuildsReportSecondsUntilReset() throws {
        let line = #"{"timestamp":"2026-10-05T20:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":50,"window_minutes":300,"resets_in_seconds":600}}}}"#
        let usage = try XCTUnwrap(AgentUsageParser.codex(rolloutText: line))
        let observed = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T20:00:00Z"))
        XCTAssertEqual(usage.windows.first?.resetsAt, observed.addingTimeInterval(600))
    }

    func testARolloutWithNoLimitsYetReportsNothing() {
        XCTAssertNil(AgentUsageParser.codex(rolloutText: #"{"payload":{"type":"token_count","rate_limits":null}}"#))
        XCTAssertNil(AgentUsageParser.codex(rolloutText: ""))
    }

    func testWindowLabels() {
        XCTAssertEqual(AgentUsageParser.windowLabel(minutes: 300), "5h")
        XCTAssertEqual(AgentUsageParser.windowLabel(minutes: 10_080), "Week")
        XCTAssertEqual(AgentUsageParser.windowLabel(minutes: 120), "2h")
        XCTAssertEqual(AgentUsageParser.windowLabel(minutes: 4320), "3d")
    }

    func testAWindowPastItsResetIsDropped() {
        let usage = AgentUsage(agent: "claude", windows: [
            UsageWindow(label: "5h", usedPercent: 90, resetsAt: now.addingTimeInterval(-1)),
            UsageWindow(label: "Week", usedPercent: 40, resetsAt: now.addingTimeInterval(60)),
        ], observedAt: now)
        XCTAssertEqual(usage.current(at: now)?.windows.map(\.label), ["Week"])
        XCTAssertNil(usage.current(at: now.addingTimeInterval(120)))
    }

    func testCodexStoreReadsTheNewestRolloutWithLimits() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/10/05")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-10-05T20:00:00.000Z","payload":{"rate_limits":{"primary":{"used_percent":33,"window_minutes":300,"resets_at":1790010000}}}}"#
        try line.write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        // A newer session that hasn't had a response yet: no limits, so the older one still counts.
        try #"{"payload":{"type":"session_meta"}}"#.write(to: day.appendingPathComponent("rollout-b.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentUsageStore.readCodex(codexHome: home.path)?.windows.first?.usedPercent, 33)
    }

    // MARK: Claude's status line inside Balagan

    func testInjectedSettingsInstallOurStatusLineAndKeepTheUsersSpacing() throws {
        let settings = ClaudeHookSettings.settingsObject(
            wrapperPath: "/Apps/Balagan.app/Contents/MacOS/balagan-agent",
            userStatusLine: ["type": "command", "command": "~/s.sh", "padding": 2, "refreshInterval": 5]
        )
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "'/Apps/Balagan.app/Contents/MacOS/balagan-agent' statusline")
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 5)
        XCTAssertNotNil(settings["hooks"])
    }

    func testFindsTheUsersStatusLineByClaudesPrecedenceAndNeverOurs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), config = root.appendingPathComponent("config")
        func write(_ command: String, _ file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #"{"statusLine":{"type":"command","command":"\#(command)"}}"#.write(to: file, atomically: true, encoding: .utf8)
        }
        try write("user.sh", config.appendingPathComponent("settings.json"))
        XCTAssertEqual(ClaudeStatusLine.userSetting(projectDirectory: project.path, configDirectory: config.path)?["command"] as? String, "user.sh")

        try write("project.sh", project.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(ClaudeStatusLine.userSetting(projectDirectory: project.path, configDirectory: config.path)?["command"] as? String, "project.sh")

        try write("/x/balagan-agent statusline", project.appendingPathComponent(".claude/settings.local.json"))
        XCTAssertEqual(ClaudeStatusLine.userSetting(projectDirectory: project.path, configDirectory: config.path)?["command"] as? String,
                       "project.sh", "our own status line is never treated as the user's")
    }

    func testTheDefaultLineShowsModelContextAndLimits() {
        let json = #"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":34.4},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1790003600}}}"#
        XCTAssertEqual(ClaudeStatusLine.defaultLine(statusLineJSON: Data(json.utf8), now: now), "Opus · ctx 34% · 5h 24%")
    }
}
