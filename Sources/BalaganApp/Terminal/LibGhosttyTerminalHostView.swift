import AppKit
import BalaganCore

final class LibGhosttyTerminalHostView: NSView {
    var shortcutContext: TerminalShortcutContext?
    var onActivate: (() -> Void)?
    var onEndedProcessSurface: ((TaskItem.ID, Surface.ID) -> Void)?
    var currentSessionKey: TerminalHostKey?
    private var library: LibGhosttyDynamicLibrary?
    var appHandle: LibGhosttyAppHandle?
    var surfaceHandle: LibGhosttySurfaceHandle?
    var renderTimer: Timer?
    var messageLabel: NSTextField?
    var currentArtifactDirectory: URL?
    var currentSurfaceID: Surface.ID?
    var lastVisibleText: String?
    var lastVisibleTextWrite = Date.distantPast
    var didRecordVisibleTextReadFailure = false
    var isActive = false
    private var pendingLaunchCommand: ResumeLaunchCommand?
    var autoCloseAfterEndedProcessPrompt = false
    var didRequestEndedProcessAutoClose = false
    var processExitDetected = false
    var lastReportedTitle: String?
    var lastReportedTitleSignal: AgentTitleHeuristic.TitleSignal?
    var lastReportedWorkingDirectory: String?
    var mouseTrackingArea: NSTrackingArea?
    // IME / text-input state for the unified (cmux-style) key pipeline.
    var markedText = NSMutableAttributedString()
    var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    var keyTextAccumulator: [String]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func configure(_ config: TerminalSessionConfig) {
        let sessionKey = config.sessionKey
        let surface = config.surface
        let runtime = config.runtime
        let terminalAppearance = config.terminalAppearance
        let artifactDirectory = config.artifactDirectory

        setAccessibilityIdentifier("libghostty-terminal-\(surface.id)")
        setAccessibilityRole(.group)
        currentArtifactDirectory = artifactDirectory
        currentSurfaceID = surface.id

        guard runtime.selection.kind == .libghostty else {
            showMessage("libghostty backend is not active")
            return
        }

        guard currentSessionKey != sessionKey || surfaceHandle == nil else {
            return
        }

        resetSessionState(sessionKey: sessionKey)

        let resolved = resolveLaunch(surface: surface, sessionKey: sessionKey, runtime: runtime)

        guard let launchCommand = resolved.command else {
            mountRestoredOnly(
                surface: surface,
                sessionKey: sessionKey,
                runtime: runtime,
                terminalAppearance: terminalAppearance,
                artifactDirectory: artifactDirectory
            )
            return
        }

        do {
            let library = try LibGhosttyDynamicLibrary.load(explicitPath: runtime.libGhosttyPath)
            try library.initializeOnce(arguments: ["Balagan"])
            let appHandle = try library.createApp()
            let scaleFactor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
            let launchProgram = buildLaunchProgram(
                surface: surface,
                launchCommand: launchCommand,
                isConfirmedResume: resolved.hadPending,
                agentWrapperPath: runtime.agentWrapperPath
            )
            let descriptor = makeSurfaceDescriptor(
                surface: surface,
                launchCommand: launchCommand,
                launchProgram: launchProgram.program,
                scaleFactor: scaleFactor,
                terminalAppearance: terminalAppearance,
                sessionKey: sessionKey,
                runtime: runtime
            )
            let surfaceHandle = try appHandle.createSurface(descriptor: descriptor)

            self.library = library
            self.appHandle = appHandle
            self.surfaceHandle = surfaceHandle
            TerminalHostRegistry.shared.surfaceLaunchedReporter?(sessionKey.taskID, surface.id)
            if launchProgram.pendingSetupCommand != nil {
                TerminalHostRegistry.shared.surfaceSetupConsumedReporter?(sessionKey.taskID, surface.id)
            }
            wireSurfaceCallbacks(surfaceHandle)
            autoCloseAfterEndedProcessPrompt = resolved.shouldAutoClose
            didRequestEndedProcessAutoClose = false
            hideMessage()
            if isActive {
                requestActiveFocus()
            } else {
                applyActiveFocus(requestFirstResponder: false)
            }
            writeHostArtifact(
                artifactDirectory: artifactDirectory,
                surface: surface,
                status: "mounted",
                message: "libghostty surface mounted",
                command: launchCommand.displayCommand,
                fontSize: terminalAppearance.fontSize
            )
            resizeSurface()
            startRenderLoop()
        } catch {
            writeHostArtifact(
                artifactDirectory: artifactDirectory,
                surface: surface,
                status: "failed",
                message: String(describing: error),
                command: launchCommand.displayCommand,
                fontSize: terminalAppearance.fontSize
            )
            showMessage("libghostty launch failed: \(error)")
        }
    }

    private func resetSessionState(sessionKey: TerminalHostKey) {
        stopTerminal()
        currentSessionKey = sessionKey
        lastVisibleText = nil
        lastVisibleTextWrite = .distantPast
        didRecordVisibleTextReadFailure = false
        processExitDetected = false
        lastReportedTitle = nil
        lastReportedTitleSignal = nil
        lastReportedWorkingDirectory = nil
    }

    /// Resolves the command to launch (a pending confirmed-resume command, else the surface's initial
    /// launch command) plus whether an ended-process prompt should auto-close. Consumes any pending
    /// launch command.
    private func resolveLaunch(
        surface: Surface,
        sessionKey: TerminalHostKey,
        runtime: TerminalRuntimeOptions
    ) -> (hadPending: Bool, command: ResumeLaunchCommand?, shouldAutoClose: Bool) {
        let hadPendingLaunchCommand = pendingLaunchCommand != nil
        let launchCommand = pendingLaunchCommand
            ?? surface.initialLaunchCommand(
                taskID: sessionKey.taskID,
                processPreference: runtime.processPreference
            )
        let shouldAutoCloseAfterEndedPrompt = pendingLaunchCommand != nil
            || surface.shouldAutoCloseAfterEndedProcessPrompt(
                taskID: sessionKey.taskID,
                processPreference: runtime.processPreference
            )
        pendingLaunchCommand = nil
        return (hadPendingLaunchCommand, launchCommand, shouldAutoCloseAfterEndedPrompt)
    }

    /// Mounts a surface that has no process to launch: reports the restored status/message and shows
    /// the restored-metadata banner (the early-return branch of `configure`).
    private func mountRestoredOnly(
        surface: Surface,
        sessionKey: TerminalHostKey,
        runtime: TerminalRuntimeOptions,
        terminalAppearance: TerminalAppearanceSettings,
        artifactDirectory: URL?
    ) {
        autoCloseAfterEndedProcessPrompt = false
        didRequestEndedProcessAutoClose = false
        let action = surface.launchAction(
            taskID: sessionKey.taskID,
            processPreference: runtime.processPreference
        )
        writeHostArtifact(
            artifactDirectory: artifactDirectory,
            surface: surface,
            status: restoredStatus(for: action),
            message: "terminal restored without process launch",
            command: nil,
            fontSize: terminalAppearance.fontSize
        )
        showMessage(restoredMessage(for: surface, taskID: sessionKey.taskID, runtime: runtime))
    }

    /// Chooses how the launch command runs: replay captured scrollback for a reopened plain shell,
    /// prepend one-time worktree setup, or wrap in the user's login+interactive shell. Returns the
    /// program plus the setup command it consumed (so the caller can fire the setup-consumed reporter).
    private func buildLaunchProgram(
        surface: Surface,
        launchCommand: ResumeLaunchCommand,
        isConfirmedResume: Bool,
        agentWrapperPath: String?
    ) -> (program: String, pendingSetupCommand: String?) {
        // A saved command can name the wrapper bare (`balagan-agent codex`), which isn't on the
        // shell's PATH. Expand it to the bundled wrapper here, at launch, so it runs however it was
        // stored (e.g. a tab created before the TaskBoard → Balagan rename, then migrated).
        var launchCommand = launchCommand
        if let expanded = AgentStartupCommandResolver.startupCommand(
            defaultAgentCommand: launchCommand.displayCommand,
            environment: [:],
            wrapperPath: agentWrapperPath
        ) {
            launchCommand.displayCommand = expanded
        }
        let replayProgram = scrollbackReplayCommand(
            for: surface,
            launchCommand: launchCommand,
            isConfirmedResume: isConfirmedResume
        )
        // One-time worktree setup: prepend the project's setup commands to the very first launch,
        // run inside the user's login shell in the worktree cwd. Consumed after mount so it never
        // re-runs (and never executes in the main repo — it's only set on a created worktree).
        let pendingSetupCommand = surface.setupCommand?.nilIfBlank
        let program: String
        if let replayProgram {
            program = replayProgram
        } else if let pendingSetupCommand {
            let shell = UserShell.defaultShellPath(environment: surface.liveEnvironment)
            let combined = pendingSetupCommand + "\n" + launchCommand.displayCommand
            program = "\(shell.shellQuoted) -lic \(combined.shellQuoted)"
        } else {
            program = loginShellLaunchProgram(
                for: launchCommand,
                environment: surface.liveEnvironment,
                agentWrapperPath: agentWrapperPath
            )
        }
        return (program, pendingSetupCommand)
    }

    /// Builds the libghostty surface descriptor: the unretained platform-view handoff and the merged
    /// launch environment (surface env < launch-command env < runtime session-report context).
    private func makeSurfaceDescriptor(
        surface: Surface,
        launchCommand: ResumeLaunchCommand,
        launchProgram: String,
        scaleFactor: Double,
        terminalAppearance: TerminalAppearanceSettings,
        sessionKey: TerminalHostKey,
        runtime: TerminalRuntimeOptions
    ) -> LibGhosttySurfaceDescriptor {
        LibGhosttySurfaceDescriptor(
            platformView: Unmanaged.passUnretained(self).toOpaque(),
            scaleFactor: scaleFactor,
            fontSize: terminalAppearance.fontSize,
            workingDirectory: surface.cwd,
            command: launchProgram,
            environment: surface.liveEnvironment
                // Any agent you type at the prompt runs through the wrapper (shims + zsh chain).
                .merging(AgentShellEnvironment.variables(
                    paths: AgentIntegrationPaths(),
                    wrapperPath: runtime.agentWrapperPath,
                    userShell: UserShell.defaultShellPath(environment: surface.liveEnvironment),
                    current: ProcessInfo.processInfo.environment.merging(surface.liveEnvironment) { _, surface in surface }
                )) { _, shell in shell }
                .merging(launchCommand.environment) { _, launch in launch }
                .merging(TerminalRuntimeLaunchContext(
                    taskID: sessionKey.taskID,
                    workspaceID: surface.workspaceID(taskID: sessionKey.taskID),
                    surfaceID: surface.id,
                    socketPath: runtime.sessionReportSocketPath
                ).environment) { _, runtime in runtime }
        )
    }

    private func wireSurfaceCallbacks(_ surfaceHandle: LibGhosttySurfaceHandle) {
        surfaceHandle.onTitleChanged = { [weak self] title in
            self?.reportSurfaceTitle(title)
        }
        surfaceHandle.onWorkingDirectoryChanged = { [weak self] pwd in
            self?.reportSurfaceWorkingDirectory(pwd)
        }
        surfaceHandle.onDesktopNotification = { [weak self] title, body in
            self?.presentDesktopNotification(title: title, body: body)
        }
        surfaceHandle.onBell = { [weak self] in
            self?.handleBell()
        }
    }

    /// Wraps a startup/agent/resume command so libghostty runs it inside the user's **login +
    /// interactive shell** — matching how a plain shell terminal launches. Without this, libghostty
    /// execs the command with the bare process environment; when the app is launched from Finder/Dock
    /// (a minimal `PATH`), brew/npm-installed agent CLIs (`codex`/`claude`) aren't found, the process
    /// exits instantly, and `wait_after_command=false` closes the tab ("agent tab immediately closes").
    /// A bare shell (argv == [shell]) is returned untouched — libghostty already runs it as a login shell.
    private func loginShellLaunchProgram(
        for launchCommand: ResumeLaunchCommand,
        environment: [String: String],
        agentWrapperPath: String?
    ) -> String {
        guard (launchCommand.argv?.count ?? 0) > 1 else {
            return launchCommand.displayCommand
        }
        // A resume launch builds a *bare* agent argv (`claude --resume <id>`, `pi --session-id <id>`,
        // `opencode --session <id>`). Run any profiled agent through the balagan-agent wrapper so its
        // integration (Claude's hooks, pi's extension, OpenCode's plugin) is active on resume too —
        // otherwise a resumed agent reports no working state. A fresh launch already goes through the
        // wrapper (its argv[0] is the shell), so this only rewrites the resume case.
        var command = launchCommand.displayCommand
        if let agentWrapperPath, let argv = launchCommand.argv, let first = argv.first,
           let profile = AgentProfiles.forCommand(first) {
            command = ([agentWrapperPath, profile.id] + argv.dropFirst()).map(\.shellQuoted).joined(separator: " ")
        }
        let shell = UserShell.defaultShellPath(environment: environment)
        return "\(shell.shellQuoted) -lic \(command.shellQuoted)"
    }

    /// For a reopened **plain shell** with captured scrollback, returns a launcher command that
    /// replays that scrollback before the shell starts. Returns nil (→ launch the shell normally)
    /// for agent/resume/confirmed-resume surfaces, or when there's only the placeholder seed.
    private func scrollbackReplayCommand(
        for surface: Surface,
        launchCommand: ResumeLaunchCommand,
        isConfirmedResume: Bool
    ) -> String? {
        guard isConfirmedResume == false,
              surface.resumeBinding == nil,
              surface.startupCommand?.nilIfBlank == nil
        else {
            return nil
        }

        guard let scrollback = surface.scrollbackSnapshot, scrollback.isEmpty == false else {
            return nil
        }

        // Skip the freshly-seeded placeholder (`<pwdPlaceholderSeed>\n<cwd>`) used by the non-live
        // fallback view.
        let lines = surface.output
        if lines.count <= 2, lines.first == Surface.pwdPlaceholderSeed {
            return nil
        }

        return TerminalScrollbackReplay.launchCommand(
            surfaceID: surface.id,
            scrollback: scrollback,
            shellPath: launchCommand.displayCommand
        )
    }

    func launchConfirmedResume(_ config: TerminalSessionConfig, command: ResumeLaunchCommand) {
        pendingLaunchCommand = command
        stopTerminal()
        currentSessionKey = nil
        configure(config)
    }

    private func restoredStatus(for action: ResumeLaunchAction) -> String {
        switch action {
        case .needsConfirmation:
            return "needs-confirmation"
        case .restoredOnly:
            return "restored-only"
        case .idle:
            return "idle"
        case .autoResume, .startupCommand, .startupShell:
            return "not-mounted"
        }
    }

    private func restoredMessage(
        for surface: Surface,
        taskID: TaskItem.ID,
        runtime: TerminalRuntimeOptions
    ) -> String {
        switch surface.launchAction(taskID: taskID, processPreference: runtime.processPreference) {
        case .needsConfirmation(let command):
            return "Resume requires confirmation:\n\(command.displayCommand)"
        case .restoredOnly(_, let reason):
            if let plan = surface.resumePlan(taskID: taskID) {
                return "Restored terminal metadata (\(reason)).\nResume available:\n\(plan.displayCommand)"
            }
            return "Restored terminal metadata (\(reason))."
        case .idle:
            return "Restored terminal metadata. No process was launched."
        case .autoResume, .startupCommand, .startupShell:
            return "Terminal is ready to launch."
        }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    /// Detaches this surface's libghostty notification/bell callbacks so a late escape — e.g. a dying
    /// agent's final bell or desktop-notification when it's SIGTERM'd on sleep — can't post a banner or
    /// flag the surface for attention after we've decided to tear it down. The global event trampoline
    /// captures the surface context *strongly* and re-dispatches onto the main queue asynchronously, so
    /// clearing the callbacks (not just dropping the handle) is what actually silences an in-flight
    /// event. Safe to call more than once. Sleep calls this synchronously *before* the SIGTERM.
    func muteEventCallbacks() {
        surfaceHandle?.onDesktopNotification = nil
        surfaceHandle?.onBell = nil
    }

    func stopTerminal() {
        renderTimer?.invalidate()
        renderTimer = nil
        muteEventCallbacks()
        surfaceHandle?.onTitleChanged = nil
        surfaceHandle?.onWorkingDirectoryChanged = nil
        surfaceHandle?.setFocus(false)
        surfaceHandle = nil
        appHandle = nil
        library = nil
        autoCloseAfterEndedProcessPrompt = false
    }

    func closeTerminalSession() {
        TerminalHostRegistry.shared.clearActiveHost(self)
        stopTerminal()
        currentSessionKey = nil
    }
}
