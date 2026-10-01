import Foundation
import XCTest
@testable import BalaganCore

final class TerminalSurfaceSessionTests: XCTestCase {
    private enum FakeRunnerError: Error, Equatable {
        case failed
    }

    private struct FakeRunner: TerminalProcessRunning {
        var result: PtyRunResult
        var onRun: (@Sendable (PtyCommand, PtyWindowSize) -> Void)?

        func run(_ command: PtyCommand, windowSize: PtyWindowSize) throws -> PtyRunResult {
            onRun?(command, windowSize)
            return result
        }
    }

    private struct FailingRunner: TerminalProcessRunning {
        func run(_ command: PtyCommand, windowSize: PtyWindowSize) throws -> PtyRunResult {
            throw FakeRunnerError.failed
        }
    }

    func testStartupCommandCreatesShellLaunchRequest() throws {
        let surface = BalaganFixtures.surface(
            startupCommand: "printf 'hello\\n'",
            resumeBinding: nil
        )

        let request = try XCTUnwrap(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "build-board"))

        XCTAssertEqual(request.surfaceID, surface.id)
        XCTAssertEqual(request.source, .startupCommand)
        XCTAssertEqual(request.command.executable, "/bin/sh")
        XCTAssertEqual(request.command.arguments, ["-lc", "printf 'hello\\n'"])
        XCTAssertEqual(request.command.workingDirectory, surface.cwd)
        XCTAssertEqual(request.command.environment["TERM"], "xterm-256color")
    }

    func testTrustedResumeBindingCreatesProcessSafeLaunchRequest() throws {
        let binding = BalaganFixtures.resumeBinding(
            kind: .agent,
            agentName: "codex",
            sessionID: "codex-session-123",
            command: "codex resume codex-session-123",
            trust: .trusted,
            source: .agentHook,
            autoResume: true,
            sanitizedEnvironment: ["BALAGAN_ALLOWED": "1"]
        )
        let surface = BalaganFixtures.surface(
            environment: ["TERM": "xterm-256color"],
            startupCommand: "codex",
            resumeBinding: binding
        )

        let request = try XCTUnwrap(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "resume-codex"))

        XCTAssertEqual(request.source, .trustedResume)
        XCTAssertEqual(request.displayCommand, "codex resume codex-session-123")
        XCTAssertEqual(request.command.executable, "codex")
        XCTAssertEqual(request.command.arguments, ["resume", "codex-session-123"])
        XCTAssertEqual(request.command.environment["TERM"], "xterm-256color")
        XCTAssertEqual(request.command.environment["BALAGAN_ALLOWED"], "1")
        XCTAssertEqual(request.command.workingDirectory, surface.cwd)
    }

    func testUntrustedResumeBindingDoesNotAutoLaunch() {
        let surface = BalaganFixtures.surface(
            startupCommand: "tmux attach -t task_build_board",
            resumeBinding: BalaganFixtures.resumeBinding(trust: .untrusted)
        )

        XCTAssertNil(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "build-board"))
    }

    func testUnknownTrustedAgentDoesNotAutoLaunchCustomCommandString() {
        let binding = BalaganFixtures.resumeBinding(
            kind: .agent,
            agentName: "unknown-agent",
            sessionID: "session-123",
            command: "unknown-agent resume session-123",
            trust: .trusted
        )
        let surface = BalaganFixtures.surface(startupCommand: nil, resumeBinding: binding)

        XCTAssertNil(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "build-board"))
    }

    func testSurfaceWithoutLaunchMetadataDoesNotCreateHeadlessLaunchRequest() {
        let surface = BalaganFixtures.surface(startupCommand: nil, resumeBinding: nil)

        XCTAssertNil(TerminalLaunchPlanner.launchRequest(for: surface, taskID: "build-board"))
    }

    func testPlainTextTerminalEmulatorNormalizesAndBoundsScrollback() {
        var emulator = PlainTextTerminalEmulator(maxLines: 3)
        emulator.feed(Data("one\r\ntwo\rthree\nfour".utf8))

        let snapshot = emulator.snapshot(
            surface: BalaganFixtures.surface(),
            exitStatus: 0
        )

        XCTAssertEqual(snapshot.lines, ["two", "three", "four"])
        XCTAssertEqual(snapshot.exitStatus, 0)
        XCTAssertEqual(snapshot.scrollbackSnapshot, "two\nthree\nfour")
    }

    func testTerminalSurfaceSessionUsesInjectedRunnerAndCapturesScrollback() throws {
        let surface = BalaganFixtures.surface(
            environment: ["TERM": "xterm-256color"],
            startupCommand: "printf 'terminal session ready\\n'",
            resumeBinding: nil,
            scrollbackSnapshot: nil
        )
        let runner = FakeRunner(result: PtyRunResult(output: Data("terminal session ready\r\n".utf8), exitStatus: 0))

        let result = try XCTUnwrap(TerminalSurfaceSession.run(surface: surface, taskID: "build-board", runner: runner))

        XCTAssertEqual(result.launchRequest.source, .startupCommand)
        XCTAssertEqual(result.transcript.exitStatus, 0)
        XCTAssertTrue(result.transcript.scrollbackSnapshot.contains("terminal session ready"))
        XCTAssertEqual(result.updatedSurface.scrollbackSnapshot, result.transcript.scrollbackSnapshot)
    }

    func testTerminalSurfaceSessionInjectsRuntimeLaunchContext() throws {
        let surface = BalaganFixtures.surface(
            id: "surface-1",
            workspaceID: "workspace-1",
            environment: ["TERM": "xterm-256color"],
            startupCommand: "env",
            resumeBinding: nil
        )
        nonisolated(unsafe) var observedCommand: PtyCommand?
        let runner = FakeRunner(
            result: PtyRunResult(output: Data("ok\r\n".utf8), exitStatus: 0),
            onRun: { command, _ in
                observedCommand = command
            }
        )

        _ = try XCTUnwrap(TerminalSurfaceSession.run(
            surface: surface,
            taskID: "task-1",
            socketPath: "/tmp/balagan.sock",
            runner: runner
        ))

        let command = try XCTUnwrap(observedCommand)
        XCTAssertEqual(command.environment["BALAGAN_TASK_ID"], "task-1")
        XCTAssertEqual(command.environment["BALAGAN_WORKSPACE_ID"], "workspace-1")
        XCTAssertEqual(command.environment["BALAGAN_SURFACE_ID"], "surface-1")
        XCTAssertEqual(command.environment["BALAGAN_SOCKET_PATH"], "/tmp/balagan.sock")
        XCTAssertEqual(command.environment["TERM"], "xterm-256color")
    }

    func testTerminalSurfaceSessionPropagatesRunnerFailureWithoutMutatingSurface() {
        let surface = BalaganFixtures.surface(
            startupCommand: "printf 'terminal session ready\\n'",
            resumeBinding: nil,
            scrollbackSnapshot: "existing scrollback"
        )

        XCTAssertThrowsError(try TerminalSurfaceSession.run(surface: surface, taskID: "build-board", runner: FailingRunner())) { error in
            XCTAssertEqual(error as? FakeRunnerError, .failed)
        }

        XCTAssertEqual(surface.scrollbackSnapshot, "existing scrollback")
    }

    func testLiveTerminalSurfaceSessionRunsStartupCommandThroughPty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalaganTerminalSurfaceSessionTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let surface = BalaganFixtures.surface(
            cwd: directory.path,
            environment: ["TERM": "xterm-256color"],
            startupCommand: "printf 'terminal session ready\\n'; pwd",
            resumeBinding: nil,
            scrollbackSnapshot: nil
        )

        let result = try XCTUnwrap(TerminalSurfaceSession.run(surface: surface, taskID: "build-board"))

        XCTAssertEqual(result.launchRequest.source, .startupCommand)
        XCTAssertEqual(result.transcript.exitStatus, 0)
        XCTAssertTrue(result.transcript.scrollbackSnapshot.contains("terminal session ready"))
        XCTAssertTrue(result.transcript.scrollbackSnapshot.contains(directory.path))
    }
}
