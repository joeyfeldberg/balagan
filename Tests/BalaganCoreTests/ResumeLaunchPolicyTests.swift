import XCTest
@testable import BalaganCore

final class ResumeLaunchPolicyTests: XCTestCase {
    func testTrustedCodexResumeAutoLaunchesNativeCommand() throws {
        let binding = BalaganFixtures.resumeBinding(
            kind: .agent,
            agentName: "codex",
            sessionID: "session-123",
            command: "codex resume session-123",
            trust: .trusted,
            source: .agentHook,
            autoResume: true
        )
        let surface = BalaganFixtures.surface(startupCommand: "codex", resumeBinding: binding)

        let action = ResumeLaunchPolicy.action(for: surface, taskID: "task-1")

        guard case .autoResume(let command) = action else {
            return XCTFail("Expected trusted Codex binding to auto resume, got \(action).")
        }
        XCTAssertEqual(command.argv, ["codex", "resume", "session-123"])
        XCTAssertEqual(command.displayCommand, "codex resume session-123")
        XCTAssertEqual(command.workingDirectory, surface.cwd)
    }

    func testTrustedTmuxResumeFallbackUsesTaskIDNotWorkspaceID() throws {
        let binding = BalaganFixtures.resumeBinding(
            kind: .tmux,
            sessionID: nil,
            command: "",
            trust: .trusted,
            source: .processDetected,
            autoResume: true
        )
        let surface = BalaganFixtures.surface(
            id: "surface-shell",
            workspaceID: "workspace-should-not-name-session",
            startupCommand: nil,
            resumeBinding: binding
        )

        let action = ResumeLaunchPolicy.action(for: surface, taskID: "Task 123:Feature/UI")

        guard case .autoResume(let command) = action else {
            return XCTFail("Expected trusted tmux binding to auto resume, got \(action).")
        }
        XCTAssertEqual(command.argv, ["tmux", "attach", "-t", "task_task_123_feature_ui"])
        XCTAssertFalse(command.displayCommand.contains("workspace"))
    }

    func testUntrustedAndCustomResumeRequireConfirmationWithoutAutoLaunch() {
        let untrustedCodex = BalaganFixtures.surface(
            resumeBinding: BalaganFixtures.resumeBinding(
                kind: .agent,
                agentName: "codex",
                sessionID: "session-123",
                command: "codex resume session-123",
                trust: .untrusted
            )
        )
        let custom = BalaganFixtures.surface(
            resumeBinding: BalaganFixtures.resumeBinding(
                kind: .custom,
                command: "dangerous resume command",
                trust: .trusted
            )
        )

        guard case .needsConfirmation(let untrustedCommand) = ResumeLaunchPolicy.action(for: untrustedCodex, taskID: "task-1") else {
            return XCTFail("Expected untrusted Codex resume to require confirmation.")
        }
        XCTAssertEqual(untrustedCommand.argv, ["codex", "resume", "session-123"])

        guard case .needsConfirmation(let customCommand) = ResumeLaunchPolicy.action(for: custom, taskID: "task-1") else {
            return XCTFail("Expected custom resume to require confirmation.")
        }
        XCTAssertNil(customCommand.argv)
        XCTAssertEqual(customCommand.displayCommand, "dangerous resume command")
    }

    func testTrustedManualResumeRequiresConfirmationWithoutAutoLaunch() {
        let surface = BalaganFixtures.surface(
            resumeBinding: BalaganFixtures.resumeBinding(
                kind: .agent,
                agentName: "codex",
                sessionID: "session-123",
                command: "codex resume session-123",
                trust: .trusted,
                source: .manual,
                autoResume: true
            )
        )

        guard case .needsConfirmation(let command) = ResumeLaunchPolicy.action(for: surface, taskID: "task-1") else {
            return XCTFail("Expected trusted manual resume to require confirmation.")
        }

        XCTAssertEqual(command.argv, ["codex", "resume", "session-123"])
    }

    func testCapturedResumeDoesNotAutoLaunchWhenStaleNonRestorableOrAutoResumeDisabled() {
        let stale = BalaganFixtures.surface(
            resumeBinding: capturedCodexBinding(id: "stale", isStale: true)
        )
        let nonRestorable = BalaganFixtures.surface(
            resumeBinding: capturedCodexBinding(id: "non-restorable", isRestorable: false)
        )
        let disabled = BalaganFixtures.surface(
            resumeBinding: capturedCodexBinding(id: "disabled", autoResume: false)
        )

        for surface in [stale, nonRestorable, disabled] {
            guard case .needsConfirmation = ResumeLaunchPolicy.action(for: surface, taskID: "task-1") else {
                return XCTFail("Expected \(surface.resumeBinding?.id ?? "unknown") to require confirmation.")
            }
        }
    }

    func testStartupCommandAndShellAreUsedOnlyWithoutResumeBinding() {
        let startupSurface = BalaganFixtures.surface(
            startupCommand: "make test",
            resumeBinding: nil
        )
        let shellSurface = BalaganFixtures.surface(
            startupCommand: nil,
            resumeBinding: nil
        )
        let resumeSurface = BalaganFixtures.surface(
            startupCommand: "make test",
            resumeBinding: BalaganFixtures.resumeBinding(trust: .untrusted)
        )

        guard case .startupCommand(let startupCommand) = ResumeLaunchPolicy.action(for: startupSurface, taskID: "task-1") else {
            return XCTFail("Expected startup command when no resume binding exists.")
        }
        XCTAssertEqual(startupCommand.argv, ["/bin/sh", "-lc", "make test"])

        guard case .startupShell(let shellCommand) = ResumeLaunchPolicy.action(for: shellSurface, taskID: "task-1") else {
            return XCTFail("Expected startup shell when no launch metadata exists.")
        }
        XCTAssertEqual(shellCommand.argv, [UserShell.defaultShellPath(environment: shellSurface.environment)])
        XCTAssertEqual(shellCommand.environment["SHELL"], UserShell.defaultShellPath(environment: shellSurface.environment))

        guard case .needsConfirmation = ResumeLaunchPolicy.action(for: resumeSurface, taskID: "task-1") else {
            return XCTFail("Expected resume binding to take precedence over startup command.")
        }
    }

    func testCapturedResumeBindingWinsOverFreshCodexStartupCommandOnReopen() {
        let surface = BalaganFixtures.surface(
            startupCommand: "'/tmp/balagan build/balagan-agent' codex",
            resumeBinding: capturedCodexBinding(id: "captured-session")
        )

        guard case .autoResume(let command) = ResumeLaunchPolicy.action(for: surface, taskID: "task-1") else {
            return XCTFail("Expected captured Codex binding to auto resume instead of using startup command.")
        }

        XCTAssertEqual(command.argv, ["codex", "resume", "session-123"])
        XCTAssertEqual(command.displayCommand, "codex resume session-123")
    }

    func testUncapturedPersistedFreshCodexAgentDoesNotStartNewSessionOnReopen() {
        let surface = BalaganFixtures.surface(
            startupCommand: "'/tmp/balagan build/balagan-agent' codex --model gpt-5",
            resumeBinding: nil,
            scrollbackSnapshot: "$ balagan-agent codex\nCodex session starting"
        )

        let action = ResumeLaunchPolicy.action(for: surface, taskID: "task-1")

        XCTAssertEqual(
            action,
            .restoredOnly(
                surfaceID: surface.id,
                reason: "Codex session recovery incomplete; fresh startup suppressed"
            )
        )
        XCTAssertNil(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "task-1"))
    }

    func testFreshCodexAgentStillStartsWithoutPersistedScrollback() {
        let surface = BalaganFixtures.surface(
            startupCommand: "'/tmp/balagan build/balagan-agent' codex --model gpt-5",
            resumeBinding: nil,
            scrollbackSnapshot: nil
        )

        guard case .startupCommand(let command) = ResumeLaunchPolicy.action(for: surface, taskID: "task-1") else {
            return XCTFail("Expected first-time Codex agent launch to use startup command.")
        }

        XCTAssertEqual(command.displayCommand, "'/tmp/balagan build/balagan-agent' codex --model gpt-5")
    }

    func testExplicitCodexResumeStartupCommandIsNotSuppressedWhenBindingIsMissing() {
        let surface = BalaganFixtures.surface(
            startupCommand: "'/tmp/balagan build/balagan-agent' codex resume session-123",
            resumeBinding: nil,
            scrollbackSnapshot: "$ codex resume session-123"
        )

        guard case .startupCommand(let command) = ResumeLaunchPolicy.action(for: surface, taskID: "task-1") else {
            return XCTFail("Expected explicit Codex resume command to remain launchable.")
        }

        XCTAssertEqual(command.displayCommand, "'/tmp/balagan build/balagan-agent' codex resume session-123")
    }

    func testStartupShellPrefersSurfaceShellEnvironment() {
        let surface = BalaganFixtures.surface(
            environment: ["SHELL": "/bin/zsh"],
            startupCommand: nil,
            resumeBinding: nil
        )

        guard case .startupShell(let shellCommand) = ResumeLaunchPolicy.action(for: surface, taskID: "task-1") else {
            return XCTFail("Expected startup shell when no launch metadata exists.")
        }

        XCTAssertEqual(shellCommand.displayCommand, "/bin/zsh")
        XCTAssertEqual(shellCommand.argv, ["/bin/zsh"])
        XCTAssertEqual(shellCommand.environment["SHELL"], "/bin/zsh")
    }

    func testStartupShellDoesNotUseSessionLookingSurfaceMetadataAsCommand() {
        let surface = BalaganFixtures.surface(
            id: "s002",
            title: "s002",
            environment: ["SHELL": "/bin/zsh"],
            startupCommand: nil,
            resumeBinding: nil
        )

        guard case .startupShell(let shellCommand) = ResumeLaunchPolicy.action(for: surface, taskID: "task-1") else {
            return XCTFail("Expected startup shell when no launch metadata exists.")
        }

        XCTAssertEqual(shellCommand.displayCommand, "/bin/zsh")
        XCTAssertEqual(shellCommand.argv, ["/bin/zsh"])
        XCTAssertNotEqual(shellCommand.displayCommand, "s002")
        XCTAssertFalse(shellCommand.argv?.contains("s002") ?? true)
    }

    func testStartupShellFallsBackToAccountShellWhenEnvironmentShellIsMissing() {
        XCTAssertEqual(
            UserShell.defaultShellPath(environment: [:], accountShell: "/bin/zsh"),
            "/bin/zsh"
        )
    }

    func testSanitizedEnvironmentOverridesSurfaceEnvironmentForResume() throws {
        let binding = BalaganFixtures.resumeBinding(
            kind: .agent,
            agentName: "codex",
            sessionID: "session-123",
            command: "codex resume session-123",
            trust: .trusted,
            source: .agentHook,
            autoResume: true,
            sanitizedEnvironment: [
                "PATH": "/sanitized/bin",
                "BALAGAN_ALLOWED": "1",
            ]
        )
        let surface = BalaganFixtures.surface(
            environment: [
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
                "SECRET_TOKEN": "not-from-binding",
            ],
            resumeBinding: binding
        )

        let action = ResumeLaunchPolicy.action(for: surface, taskID: "task-1")

        guard case .autoResume(let command) = action else {
            return XCTFail("Expected trusted Codex binding to auto resume, got \(action).")
        }
        XCTAssertEqual(command.environment["PATH"], "/sanitized/bin")
        XCTAssertEqual(command.environment["TERM"], "xterm-256color")
        XCTAssertEqual(command.environment["BALAGAN_ALLOWED"], "1")
        XCTAssertEqual(command.environment["SECRET_TOKEN"], "not-from-binding")
    }

    func testSanitizedCapturedEnvironmentDropsSecretsAndMergesIntoLaunchCommand() throws {
        let sanitized = EnvironmentSanitizer.sanitize(
            [
                "API_TOKEN": "drop",
                "PATH": "/captured/bin",
                "BALAGAN_ALLOWED": "1",
                "TERM": "xterm-256color",
            ],
            allowlist: ["API_TOKEN", "PATH", "BALAGAN_ALLOWED", "TERM"]
        )
        let binding = capturedCodexBinding(sanitizedEnvironment: sanitized)
        let surface = BalaganFixtures.surface(
            environment: [
                "PATH": "/usr/bin:/bin",
                "TERM": "screen-256color",
            ],
            resumeBinding: binding
        )

        let action = ResumeLaunchPolicy.action(for: surface, taskID: "task-1")

        guard case .autoResume(let command) = action else {
            return XCTFail("Expected trusted captured Codex binding to auto resume, got \(action).")
        }
        XCTAssertEqual(command.environment["PATH"], "/captured/bin")
        XCTAssertEqual(command.environment["TERM"], "xterm-256color")
        XCTAssertEqual(command.environment["BALAGAN_ALLOWED"], "1")
        XCTAssertNil(command.environment["API_TOKEN"])
    }

    func testRestoreOnlyPreferenceDoesNotImplyLiveProcessCheckpointing() {
        let surface = BalaganFixtures.surface(
            resumeBinding: BalaganFixtures.resumeBinding(
                kind: .agent,
                agentName: "codex",
                sessionID: "session-123",
                command: "codex resume session-123",
                trust: .trusted,
                source: .agentHook,
                autoResume: true
            ),
            scrollbackSnapshot: "persisted transcript only"
        )

        let action = ResumeLaunchPolicy.action(
            for: surface,
            taskID: "task-1",
            processPreference: .restoreOnly
        )

        XCTAssertEqual(action, .restoredOnly(surfaceID: surface.id, reason: "process launch disabled"))
    }

    private func capturedCodexBinding(
        id: ResumeBinding.ID = "captured-codex",
        isRestorable: Bool = true,
        isStale: Bool = false,
        autoResume: Bool = true,
        sanitizedEnvironment: [String: String] = [:]
    ) -> ResumeBinding {
        BalaganFixtures.resumeBinding(
            id: id,
            kind: .agent,
            agentName: "codex",
            sessionID: "session-123",
            command: "codex resume session-123",
            trust: .trusted,
            source: .agentHook,
            pid: 4242,
            executablePath: "/opt/homebrew/bin/codex",
            argv: ["codex"],
            cwd: "/tmp/balagan",
            capturedAt: BalaganFixtures.baseDate,
            captureUpdatedAt: BalaganFixtures.laterDate,
            wasRunning: true,
            isRestorable: isRestorable,
            isStale: isStale,
            autoResume: autoResume,
            transcriptPath: "/tmp/balagan/transcripts/session-123.log",
            sanitizedEnvironment: sanitizedEnvironment
        )
    }
}
