import XCTest
@testable import BalaganCore

final class AutoSleepPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func task(
        _ id: String,
        idleMinutes: Double = 60,
        onScreen: Bool = false,
        asleep: Bool = false,
        live: Bool = true,
        unseen: Bool = false,
        surfaces: [AutoSleepPlanner.SurfaceState] = [.agentIdle]
    ) -> AutoSleepPlanner.TaskInput {
        .init(
            taskID: id,
            isOnScreen: onScreen,
            isAsleep: asleep,
            hasLiveTerminals: live,
            hasUnseenResult: unseen,
            lastActiveAt: now.addingTimeInterval(-idleMinutes * 60),
            surfaces: surfaces
        )
    }

    private func plan(_ tasks: [AutoSleepPlanner.TaskInput], threshold: Double? = 30, pressure: Bool = false) -> [String] {
        AutoSleepPlanner.tasksToSleep(tasks, now: now, idleThreshold: threshold.map { $0 * 60 }, underMemoryPressure: pressure)
    }

    func testSleepsQuietResumableTasksLongestIdleFirst() {
        let tasks = [
            task("recent", idleMinutes: 10),
            task("old", idleMinutes: 90),
            task("older", idleMinutes: 200, surfaces: [.agentIdle, .shellIdle]),
        ]
        XCTAssertEqual(plan(tasks), ["older", "old"])
    }

    func testNeverSleepsWhatStillMatters() {
        let tasks = [
            task("on-screen", onScreen: true),
            task("already-asleep", asleep: true),
            task("no-terminals", live: false),
            task("unseen-result", unseen: true),
            task("agent-working", surfaces: [.agentActive]),
            task("dev-server", surfaces: [.agentIdle, .shellBusy]),
        ]
        XCTAssertEqual(plan(tasks), [])
    }

    func testMemoryPressureShortensTheWait() {
        let tasks = [task("five-minutes", idleMinutes: 5), task("one-minute", idleMinutes: 1)]
        XCTAssertEqual(plan(tasks), [])
        XCTAssertEqual(plan(tasks, pressure: true), ["five-minutes"])
    }

    func testTimerOffStillRespondsToMemoryPressure() {
        let tasks = [task("idle", idleMinutes: 500)]
        XCTAssertEqual(plan(tasks, threshold: nil), [])
        XCTAssertEqual(plan(tasks, threshold: nil, pressure: true), ["idle"])
    }

    func testReasonWording() {
        XCTAssertEqual(
            AutoSleepPlanner.reason(idleSince: now.addingTimeInterval(-31 * 60), sleptAt: now, underMemoryPressure: false),
            "Slept after 31m idle"
        )
        XCTAssertEqual(
            AutoSleepPlanner.reason(idleSince: now.addingTimeInterval(-3 * 60), sleptAt: now, underMemoryPressure: true),
            "Slept to free memory after 3m idle"
        )
    }
}

final class GhosttyConfigOverridesTests: XCTestCase {
    func testForcesIntegrationForEnvInjectedShells() {
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/bin/zsh", userConfigText: ""), ["shell-integration = zsh"])
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/opt/homebrew/bin/fish", userConfigText: "theme = x"), ["shell-integration = fish"])
    }

    func testLeavesBashAndOthersAlone() {
        // Bash integration rewrites the command line, which would break the replay launch.
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/bin/bash", userConfigText: ""), [])
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/bin/sh", userConfigText: ""), [])
    }

    func testRespectsTheUsersOwnSetting() {
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/bin/zsh", userConfigText: "shell-integration = none"), [])
        XCTAssertEqual(GhosttyConfigOverrides.lines(userShell: "/bin/zsh", userConfigText: "  shell-integration=detect  "), [])
        // A commented-out line doesn't count.
        XCTAssertEqual(
            GhosttyConfigOverrides.lines(userShell: "/bin/zsh", userConfigText: "# shell-integration = none\nfont-size = 13"),
            ["shell-integration = zsh"]
        )
        // Nor does a different key that merely contains the words.
        XCTAssertEqual(
            GhosttyConfigOverrides.lines(userShell: "/bin/zsh", userConfigText: "shell-integration-features = no-cursor"),
            ["shell-integration = zsh"]
        )
    }
}
