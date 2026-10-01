import Darwin
import Foundation

struct LaunchOptions {
    var fixtureName: String
    var fixturePath: URL?
    var statePath: URL?
    var databasePath: URL?
    var artifactDirectory: URL?
    var uiTestMode: Bool
    var disableRealProcesses: Bool
    var recordSelectedResume: Bool
    var runUIFlowSmoke: Bool
    var captureTerminalState: Bool
    var runAgentReopenCaptureSmoke: Bool
    var libGhosttyPath: String?
    var agentWrapperPath: String?
    var sessionReportSocketPath: String
    var controlSocketPath: String?
    var controlCLILinkDirectory: String?
    var usesDefaultDatabase: Bool
    var fixtureNameWasExplicit: Bool

    /// The mutable parse state assembled across `parseArguments` + `applyEnvironmentFallbacks` before
    /// it is frozen into a `LaunchOptions`.
    private struct ParseState {
        var fixtureName = "multi-project-running"
        var fixtureNameWasExplicit = false
        var fixturePath: URL?
        var statePath: URL?
        var databasePath: URL?
        var artifactDirectory: URL?
        var uiTestMode = false
        var disableRealProcesses = false
        var recordSelectedResume = false
        var runUIFlowSmoke = false
        var captureTerminalState = false
        var runAgentReopenCaptureSmoke = false
        var libGhosttyPath: String?
        var agentWrapperPath: String?
        var sessionReportSocketPath: String?
        var controlSocketPath: String?
        var controlCLILinkDirectory: String?
        var usesDefaultDatabase = false
    }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var state = parseArguments(arguments)
        applyEnvironmentFallbacks(&state)

        return LaunchOptions(
            fixtureName: state.fixtureName,
            fixturePath: state.fixturePath,
            statePath: state.statePath,
            databasePath: state.databasePath,
            artifactDirectory: state.artifactDirectory,
            uiTestMode: state.uiTestMode,
            disableRealProcesses: state.disableRealProcesses,
            recordSelectedResume: state.recordSelectedResume,
            runUIFlowSmoke: state.runUIFlowSmoke,
            captureTerminalState: state.captureTerminalState,
            runAgentReopenCaptureSmoke: state.runAgentReopenCaptureSmoke,
            libGhosttyPath: state.libGhosttyPath,
            agentWrapperPath: state.agentWrapperPath,
            sessionReportSocketPath: resolveSessionReportSocketPath(
                explicit: state.sessionReportSocketPath,
                artifactDirectory: state.artifactDirectory
            ),
            controlSocketPath: state.controlSocketPath,
            controlCLILinkDirectory: state.controlCLILinkDirectory,
            usesDefaultDatabase: state.usesDefaultDatabase,
            fixtureNameWasExplicit: state.fixtureNameWasExplicit
        )
    }

    private static func parseArguments(_ arguments: [String]) -> ParseState {
        var state = ParseState()

        for index in arguments.indices {
            switch arguments[index] {
            case "--fixture" where arguments.indices.contains(index + 1):
                state.fixtureName = arguments[index + 1]
                state.fixtureNameWasExplicit = true
            case "--fixture-path" where arguments.indices.contains(index + 1):
                state.fixturePath = URL(fileURLWithPath: arguments[index + 1])
            case "--state-path" where arguments.indices.contains(index + 1):
                state.statePath = URL(fileURLWithPath: arguments[index + 1])
            case "--database" where arguments.indices.contains(index + 1):
                state.databasePath = URL(fileURLWithPath: arguments[index + 1])
            case "--artifact-dir" where arguments.indices.contains(index + 1):
                state.artifactDirectory = URL(fileURLWithPath: arguments[index + 1])
            case "--ui-test-mode":
                state.uiTestMode = true
            case "--record-selected-resume":
                state.recordSelectedResume = true
            case "--run-ui-flow-smoke":
                state.runUIFlowSmoke = true
            case "--capture-terminal-state":
                state.captureTerminalState = true
            case "--run-agent-reopen-capture-smoke":
                state.runAgentReopenCaptureSmoke = true
            case "--libghostty-path" where arguments.indices.contains(index + 1):
                state.libGhosttyPath = arguments[index + 1]
            case "--agent-wrapper-path" where arguments.indices.contains(index + 1):
                state.agentWrapperPath = arguments[index + 1]
            case "--session-report-socket" where arguments.indices.contains(index + 1):
                state.sessionReportSocketPath = arguments[index + 1]
            case "--control-socket" where arguments.indices.contains(index + 1):
                state.controlSocketPath = arguments[index + 1]
            case "--control-cli-link-dir" where arguments.indices.contains(index + 1):
                state.controlCLILinkDirectory = arguments[index + 1]
            default:
                continue
            }
        }

        return state
    }

    private static func applyEnvironmentFallbacks(_ state: inout ParseState) {
        if state.fixturePath == nil, let environmentPath = ProcessInfo.processInfo.environment["BALAGAN_FIXTURE_PATH"] {
            state.fixturePath = URL(fileURLWithPath: environmentPath)
        }
        if state.statePath == nil, let environmentPath = ProcessInfo.processInfo.environment["BALAGAN_STATE_PATH"] {
            state.statePath = URL(fileURLWithPath: environmentPath)
        }
        if state.databasePath == nil, let environmentPath = ProcessInfo.processInfo.environment["BALAGAN_SQLITE_PATH"] {
            state.databasePath = URL(fileURLWithPath: environmentPath)
        }
        if state.artifactDirectory == nil, let environmentPath = ProcessInfo.processInfo.environment["BALAGAN_UI_TEST_ARTIFACT_DIR"] {
            state.artifactDirectory = URL(fileURLWithPath: environmentPath)
        }
        if ProcessInfo.processInfo.environment["BALAGAN_RECORD_SELECTED_RESUME"] == "1" {
            state.recordSelectedResume = true
        }
        if ProcessInfo.processInfo.environment["BALAGAN_RUN_UI_FLOW_SMOKE"] == "1" {
            state.runUIFlowSmoke = true
        }
        if ProcessInfo.processInfo.environment["BALAGAN_CAPTURE_TERMINAL_STATE"] == "1" {
            state.captureTerminalState = true
        }
        if ProcessInfo.processInfo.environment["BALAGAN_RUN_AGENT_REOPEN_CAPTURE_SMOKE"] == "1" {
            state.runAgentReopenCaptureSmoke = true
        }
        if ProcessInfo.processInfo.environment["BALAGAN_DISABLE_REAL_PROCESSES"] == "1" {
            state.disableRealProcesses = true
        }
        if state.libGhosttyPath == nil, let environmentPath = ProcessInfo.processInfo.environment["BALAGAN_LIBGHOSTTY_PATH"] {
            state.libGhosttyPath = environmentPath
        }
        if state.agentWrapperPath == nil,
           let environmentPath = ProcessInfo.processInfo.environment["BALAGAN_AGENT_WRAPPER_PATH"],
           environmentPath.isEmpty == false {
            state.agentWrapperPath = environmentPath
        }
        if state.agentWrapperPath == nil {
            state.agentWrapperPath = discoverAgentWrapperPath()
        }
        // Deliberately do NOT read BALAGAN_SOCKET_PATH from the environment here. That variable is
        // what *we inject into agent terminals* so the agent can find this app's session-report server.
        // If Balagan is launched from inside one of its own agent terminals (e.g. dogfooding) the var
        // is present in our env — adopting it would make a new instance bind/point at another (often
        // dead) instance's socket, yielding "connect(...) failed with errno 61" (ECONNREFUSED) on a
        // stale socket file. The path is resolved below (explicit flag → artifact dir → the stable
        // ~/.balagan default, all rebound on launch); explicit override is via
        // --session-report-socket.

        if state.databasePath == nil, !state.uiTestMode {
            state.databasePath = defaultDatabasePath()
            state.usesDefaultDatabase = true
        }
    }

    /// The default session-report socket: `~/.balagan/session-report.sock`, alongside the control
    /// socket. Stable on purpose — a per-launch random path meant a stale socket file per run and left
    /// nothing to point a hook at when debugging by hand.
    static func defaultSessionReportSocketPath(homeDirectory: String = NSHomeDirectory()) -> String {
        homeDirectory + "/.balagan/session-report.sock"
    }

    /// Resolves the AF_UNIX session-report socket path: `--session-report-socket`, else a path inside
    /// `--artifact-dir` (so a test launch never touches the live app's socket), else the stable
    /// default. These paths are capped at ~104 bytes (`sun_path`); the per-user temp dir
    /// (`/var/folders/<…>/T/`) plus a full UUID overflows that, which made the agent log "session
    /// report failed (continuing): socket path is too long", so an overlong candidate falls back to a
    /// short `/tmp` path.
    static func resolveSessionReportSocketPath(
        explicit: String?,
        artifactDirectory: URL?,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let maxSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let preferredSessionReportSocketPath = explicit
            ?? artifactDirectory?.appendingPathComponent("balagan-session-report.sock").path
            ?? defaultSessionReportSocketPath(homeDirectory: homeDirectory)
        if preferredSessionReportSocketPath.utf8.count < maxSocketPathLength {
            return preferredSessionReportSocketPath
        } else {
            return "/tmp/tb-\(UUID().uuidString.prefix(8))-sr.sock"
        }
    }

    private static func defaultDatabasePath() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return baseDirectory
            .appendingPathComponent("Balagan", isDirectory: true)
            .appendingPathComponent("Balagan.sqlite")
    }

    private static func discoverAgentWrapperPath() -> String? {
        guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }

        let candidates = [
            executableDirectory.appendingPathComponent("balagan-agent"),
            executableDirectory.deletingLastPathComponent().appendingPathComponent("balagan-agent"),
        ]

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }?.path
    }
}
