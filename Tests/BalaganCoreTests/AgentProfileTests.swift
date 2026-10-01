import XCTest
@testable import BalaganCore

final class AgentProfileTests: XCTestCase {
    func testBuiltInsCoverTheFourAgents() {
        XCTAssertEqual(AgentProfiles.builtIns.map(\.id), ["claude", "codex", "opencode", "pi"])
        XCTAssertEqual(AgentProfiles.named("OpenCode")?.displayName, "OpenCode")
        XCTAssertEqual(AgentProfiles.forCommand("/opt/homebrew/bin/codex")?.id, "codex")
        XCTAssertEqual(AgentKind.named("pi")?.profile?.command, "pi")
    }

    func testResumeCommands() {
        XCTAssertEqual(AgentProfiles.claude.resumeArgv(sessionID: "s"), ["claude", "--resume", "s"])
        XCTAssertEqual(AgentProfiles.codex.resumeArgv(sessionID: "s"), ["codex", "resume", "s"])
        XCTAssertEqual(AgentProfiles.opencode.resumeArgv(sessionID: "ses_1"), ["opencode", "--session", "ses_1"])
        XCTAssertEqual(AgentProfiles.pi.resumeArgv(sessionID: "u"), ["pi", "--session-id", "u"])
        let noResume = AgentProfile(id: "x", displayName: "X", command: "x")
        XCTAssertNil(noResume.resumeArgv(sessionID: "s"))
    }

    func testCustomProfilesLoadWithDefaultsAndCantImpersonateBuiltIns() throws {
        let dir = NSTemporaryDirectory() + "agents-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{"id":"Goose","resumeArguments":["session","resume","--name","{session}"],"integration":"claudeHooks"}"#
            .write(toFile: dir + "/goose.json", atomically: true, encoding: .utf8)
        try #"{"id":"codex","command":"evil"}"#.write(toFile: dir + "/codex.json", atomically: true, encoding: .utf8)
        try #"{"id":"bad","command":"../../bin/sh"}"#.write(toFile: dir + "/bad.json", atomically: true, encoding: .utf8)
        try "not json".write(toFile: dir + "/broken.json", atomically: true, encoding: .utf8)

        let profiles = AgentProfiles.loadCustom(directory: dir)
        XCTAssertEqual(profiles.map(\.id), ["claude", "codex", "opencode", "pi", "goose"])
        let goose = try XCTUnwrap(profiles.last)
        XCTAssertEqual(goose.command, "goose", "command defaults to the id")
        XCTAssertNil(goose.integration, "only built-ins get deep integrations")
        XCTAssertEqual(goose.resumeArgv(sessionID: "n"), ["goose", "session", "resume", "--name", "n"])
        XCTAssertEqual(profiles.first { $0.id == "codex" }?.command, "codex")
    }

    // MARK: - Classification

    func testInteractiveRunsBecomeAgentTabsButSubcommandsDont() {
        XCTAssertTrue(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.codex, arguments: []))
        XCTAssertTrue(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.codex, arguments: ["fix the flaky test"]))
        XCTAssertTrue(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.codex, arguments: ["resume", "abc"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.codex, arguments: ["login"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.codex, arguments: ["exec", "do it"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.claude, arguments: ["-p", "hi"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.claude, arguments: ["mcp", "list"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.opencode, arguments: ["run", "hi"]))
        XCTAssertTrue(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.opencode, arguments: ["--model", "x/y"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.pi, arguments: ["--print", "hi"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.pi, arguments: ["--mode=json"]))
        XCTAssertFalse(AgentLaunchClassifier.isInteractiveRun(AgentProfiles.pi, arguments: ["install", "x"]))
    }

    func testNamedSessions() {
        XCTAssertEqual(AgentLaunchClassifier.namedSession(AgentProfiles.opencode, arguments: ["-s", "ses_9"]), "ses_9")
        XCTAssertEqual(AgentLaunchClassifier.namedSession(AgentProfiles.pi, arguments: ["--session-id=u1"]), "u1")
        XCTAssertNil(AgentLaunchClassifier.namedSession(AgentProfiles.pi, arguments: ["--continue"]))
        XCTAssertTrue(AgentLaunchClassifier.userChoseSession(AgentProfiles.pi, arguments: ["-c"]))
        XCTAssertFalse(AgentLaunchClassifier.userChoseSession(AgentProfiles.pi, arguments: ["fix it"]))
    }

    func testResolverSkipsTheShims() {
        let found = AgentExecutableResolver.resolve(
            command: "codex",
            path: "/tb/shims:/opt/homebrew/bin:/usr/bin",
            excluding: ["/tb/shims/"],
            isExecutable: { $0 == "/tb/shims/codex" || $0 == "/opt/homebrew/bin/codex" }
        )
        XCTAssertEqual(found, "/opt/homebrew/bin/codex")
        XCTAssertNil(AgentExecutableResolver.resolve(command: "codex", path: "/tb/shims", excluding: ["/tb/shims"], isExecutable: { _ in true }))
    }

    // MARK: - Planning

    private let env = ["PATH": "/tb/shims:/bin", "BALAGAN_SHIMS_DIR": "/tb/shims", "BALAGAN_AGENT_NAME": "Fix login"]
    private func plan(_ argv: [String], env extra: [String: String] = [:]) throws -> AgentWrapperPlan {
        try AgentWrapperPlanner.plan(
            commandLineArguments: ["balagan-agent"] + argv,
            environment: env.merging(extra) { _, new in new },
            uuid: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! },
            isExecutable: { $0 == "/bin/pi" || $0 == "/bin/opencode" || $0 == "/bin/codex" || $0 == "/bin/claude" }
        )
    }

    func testPiGetsASessionIDAndTheTaskName() throws {
        let p = try plan(["pi", "fix it"])
        XCTAssertEqual(p.mode, .agent)
        XCTAssertEqual(p.executablePath, "/bin/pi", "real binary, not the shim")
        XCTAssertEqual(p.sessionID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(p.arguments, ["--name", "Fix login", "--session-id", "11111111-2222-3333-4444-555555555555", "fix it"])
        XCTAssertEqual(p.command, "pi --session-id 11111111-2222-3333-4444-555555555555")
    }

    func testPiWithItsOwnSessionChoiceIsLeftAlone() throws {
        let p = try plan(["pi", "--continue"])
        XCTAssertNil(p.sessionID)
        XCTAssertEqual(p.arguments, ["--continue"])
    }

    func testOpenCodeWaitsForItsPluginToReportTheSession() throws {
        let fresh = try plan(["opencode"])
        XCTAssertEqual(fresh.mode, .agent)
        XCTAssertNil(fresh.sessionID)
        XCTAssertEqual(fresh.executablePath, "/bin/opencode")
        let resumed = try plan(["opencode", "--session", "ses_7"])
        XCTAssertEqual(resumed.sessionID, "ses_7")
        XCTAssertEqual(resumed.command, "opencode --session ses_7")
    }

    func testSubcommandsAndNestedRunsPassThrough() throws {
        XCTAssertEqual(try plan(["codex", "login"]).mode, .passthrough)
        let nested = try plan(["claude", "fix"], env: ["BALAGAN_AGENT_ACTIVE": "1"])
        XCTAssertEqual(nested.mode, .passthrough)
        XCTAssertEqual(nested.arguments, ["fix"], "nothing injected")
        XCTAssertEqual(nested.executablePath, "/bin/claude")
    }

    func testClaudeAndCodexKeepTheirPlans() throws {
        let claude = try plan(["claude"])
        XCTAssertEqual(claude.sessionID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(Array(claude.arguments.prefix(2)), ["--session-id", "11111111-2222-3333-4444-555555555555"])
        let codex = try plan(["codex", "resume", "abc"])
        XCTAssertEqual(codex.sessionID, "abc")
        XCTAssertFalse(codex.needsCodexSessionCapture)
        XCTAssertTrue(try plan(["codex"]).needsCodexSessionCapture)
    }

    func testUnknownAgentIsRejected() {
        XCTAssertThrowsError(try plan(["nope"]))
    }

    // MARK: - Reports

    func testReportCommands() {
        XCTAssertEqual(AgentReportCommand.parse(["pi", "lifecycle", "needs-input"])?.kind, .lifecycle(.needsInput))
        XCTAssertEqual(
            AgentReportCommand.parse(["opencode", "session", "ses_1"])?.kind,
            .session(id: "ses_1", transcriptPath: nil)
        )
        XCTAssertEqual(
            AgentReportCommand.parse(["pi", "session", "u", "/x.jsonl"])?.kind,
            .session(id: "u", transcriptPath: "/x.jsonl")
        )
        XCTAssertNil(AgentReportCommand.parse(["pi", "lifecycle", "dancing"]))
        XCTAssertNil(AgentReportCommand.parse(["pi", "session"]))

        let event = AgentReportCommand.parse(["opencode", "session", "ses_1"])!.event(
            environment: AgentWrapperEnvironment(taskID: "t", workspaceID: "w", surfaceID: "s", socketPath: "/x"),
            processEnvironment: [:],
            cwd: "/repo"
        )
        XCTAssertEqual(event.event, .sessionStart)
        XCTAssertEqual(event.command, "opencode --session ses_1")
    }

    // MARK: - Terminal environment

    func testOnlyZshGetsTheStartupChain() {
        let paths = AgentIntegrationPaths(root: "/tb")
        let zsh = AgentShellEnvironment.variables(paths: paths, wrapperPath: "/app/balagan-agent", userShell: "/bin/zsh", current: ["PATH": "/usr/bin"])
        XCTAssertEqual(zsh["PATH"], "/tb/shims:/usr/bin")
        XCTAssertEqual(zsh["ZDOTDIR"], "/tb/shell/zsh")
        XCTAssertEqual(zsh["BALAGAN_AGENT_WRAPPER"], "/app/balagan-agent")
        XCTAssertNil(zsh["BALAGAN_USER_ZDOTDIR"])

        let custom = AgentShellEnvironment.variables(paths: paths, wrapperPath: "/w", userShell: "zsh", current: ["ZDOTDIR": "/home/.config/zsh"])
        XCTAssertEqual(custom["BALAGAN_USER_ZDOTDIR"], "/home/.config/zsh")

        let bash = AgentShellEnvironment.variables(paths: paths, wrapperPath: "/w", userShell: "/bin/bash", current: [:])
        XCTAssertNil(bash["ZDOTDIR"])
        XCTAssertEqual(AgentShellEnvironment.variables(paths: paths, wrapperPath: nil, userShell: "zsh", current: [:]), [:])
    }
}

/// Runs the generated shims and zsh chain in a real zsh against a fake home, the way a Balagan
/// terminal does.
final class AgentShellIntegrationTests: XCTestCase {
    private var root: String!
    private var home: String!
    private var paths: AgentIntegrationPaths!

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "tb-shell-\(UUID().uuidString.prefix(8))"
        root = base + "/balagan"
        home = base + "/home"
        paths = AgentIntegrationPaths(root: root)
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        // A "real" codex, and a .zshrc that puts it in front of everything — like Homebrew or mise.
        try "#!/bin/sh\necho real-codex \"$@\"\n".write(toFile: home + "/bin/codex", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/bin/codex")
        try "export PATH=\"\(home!)/bin:$PATH\"\nexport USER_ZSHRC_RAN=1\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        try "export USER_ZSHENV_RAN=1\n".write(toFile: home + "/.zshenv", atomically: true, encoding: .utf8)
        AgentIntegrationInstaller.install(paths: paths, profiles: AgentProfiles.builtIns)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    private func zsh(_ script: String, login: Bool, extra: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [login ? "-lic" : "-ic", script]
        var environment = ["HOME": home!, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
        environment.merge(AgentShellEnvironment.variables(
            paths: paths, wrapperPath: "/nonexistent/balagan-agent", userShell: "/bin/zsh", current: environment
        )) { _, new in new }
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testShimsWinOverTheUsersPathAndTheirStartupFilesStillRun() throws {
        for login in [true, false] {
            let out = try zsh("print -r -- $USER_ZSHENV_RAN $USER_ZSHRC_RAN; command -v codex; print -r -- ${ZDOTDIR:-unset}", login: login)
            let lines = out.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first, "1 1", "your .zshenv and .zshrc still run (login: \(login))")
            XCTAssertEqual(lines.dropFirst().first, paths.shims + "/codex", "the shim wins (login: \(login))")
            XCTAssertEqual(lines.last, "unset", "ZDOTDIR is handed back (login: \(login))")
        }
    }

    func testTheShimRunsTheRealBinaryOutsideBalagan() throws {
        // No BALAGAN_SURFACE_ID (or no wrapper) → the real codex, found past the shims folder.
        let out = try zsh("codex hello", login: false)
        XCTAssertEqual(out, "real-codex hello")
    }

    func testAUserZDOTDIRIsFollowed() throws {
        let custom = home + "/.config/zsh"
        try FileManager.default.createDirectory(atPath: custom, withIntermediateDirectories: true)
        try "ZDOTDIR=\"\(custom)\"\n".write(toFile: home + "/.zshenv", atomically: true, encoding: .utf8)
        try "export CUSTOM_ZSHRC_RAN=1\n".write(toFile: custom + "/.zshrc", atomically: true, encoding: .utf8)
        let out = try zsh("print -r -- ${CUSTOM_ZSHRC_RAN:-no} $ZDOTDIR", login: true)
        XCTAssertEqual(out, "1 \(custom)")
    }
}
