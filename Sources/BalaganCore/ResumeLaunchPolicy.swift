import Foundation

public enum ResumeLaunchProcessPreference: String, Codable, Equatable, Hashable, Sendable {
    case allowProcessLaunch
    case restoreOnly
}

public enum ResumeLaunchAction: Equatable, Sendable {
    case idle(surfaceID: Surface.ID)
    case restoredOnly(surfaceID: Surface.ID, reason: String)
    case autoResume(ResumeLaunchCommand)
    case needsConfirmation(ResumeLaunchCommand)
    case startupCommand(ResumeLaunchCommand)
    case startupShell(ResumeLaunchCommand)
}

public struct ResumeLaunchCommand: Equatable, Sendable {
    public var surfaceID: Surface.ID
    public var displayCommand: String
    public var argv: [String]?
    public var environment: [String: String]
    public var workingDirectory: String

    public init(
        surfaceID: Surface.ID,
        displayCommand: String,
        argv: [String]?,
        environment: [String: String],
        workingDirectory: String
    ) {
        self.surfaceID = surfaceID
        self.displayCommand = displayCommand
        self.argv = argv
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public var ptyCommand: PtyCommand? {
        guard let argv,
              let executable = argv.first
        else {
            return nil
        }

        return PtyCommand(
            executable: executable,
            arguments: Array(argv.dropFirst()),
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}

public enum ResumeLaunchPolicy {
    /// Plans restart behavior from persisted surface metadata only.
    /// This does not represent a live process checkpoint; live sessions must be
    /// recovered by launching the planned resume/startup command.
    public static func action(
        for surface: Surface,
        taskID: Task.ID,
        processPreference: ResumeLaunchProcessPreference = .allowProcessLaunch
    ) -> ResumeLaunchAction {
        if processPreference == .restoreOnly {
            return .restoredOnly(surfaceID: surface.id, reason: "process launch disabled")
        }

        if let binding = surface.resumeBinding {
            return resumeAction(for: binding, surface: surface, taskID: taskID)
        }

        if let startupCommand = surface.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           startupCommand.isEmpty == false {
            if isUncapturedFreshCodexAgentRestore(surface: surface, startupCommand: startupCommand) {
                return .restoredOnly(
                    surfaceID: surface.id,
                    reason: "Codex session recovery incomplete; fresh startup suppressed"
                )
            }
            return .startupCommand(
                ResumeLaunchCommand(
                    surfaceID: surface.id,
                    displayCommand: startupCommand,
                    argv: ["/bin/sh", "-lc", startupCommand],
                    environment: surface.environment,
                    workingDirectory: surface.cwd
                )
            )
        }

        let shellPath = UserShell.defaultShellPath(environment: surface.environment)
        var shellEnvironment = surface.environment
        shellEnvironment["SHELL"] = shellEnvironment["SHELL"] ?? shellPath
        return .startupShell(
            ResumeLaunchCommand(
                surfaceID: surface.id,
                displayCommand: shellPath,
                argv: [shellPath],
                environment: shellEnvironment,
                workingDirectory: surface.cwd
            )
        )
    }

    private static func isUncapturedFreshCodexAgentRestore(surface: Surface, startupCommand: String) -> Bool {
        guard let snapshot = surface.scrollbackSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines),
              snapshot.isEmpty == false,
              CodexCommandHeuristics.snapshotContainsFreshCodexLaunch(snapshot)
        else {
            return false
        }

        guard CodexCommandHeuristics.isFreshBalaganCodexCommand(startupCommand) else {
            return false
        }

        return true
    }

    private static func resumeAction(
        for binding: ResumeBinding,
        surface: Surface,
        taskID: Task.ID
    ) -> ResumeLaunchAction {
        let plan = ResumeCommandPlanner.plan(for: binding, taskID: taskID, cwd: surface.cwd)
        let command = ResumeLaunchCommand(
            surfaceID: surface.id,
            displayCommand: plan.displayCommand,
            argv: plan.argv,
            environment: surface.environment.merging(binding.sanitizedEnvironment) { _, sanitized in sanitized },
            workingDirectory: surface.cwd
        )

        guard binding.allowsAutomaticLaunch,
              plan.requiresConfirmation == false,
              plan.trust == .trusted,
              command.argv != nil
        else {
            return .needsConfirmation(command)
        }

        return .autoResume(command)
    }
}
