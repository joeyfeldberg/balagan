import Foundation

public enum AgentCommandDefaults {
    public static let codex = "balagan-agent codex"
    public static let claude = "balagan-agent claude"
    public static let opencode = "balagan-agent opencode"
    public static let pi = "balagan-agent pi"

    /// The launch command for any profiled agent.
    public static func command(for profileID: String) -> String { "balagan-agent \(profileID)" }
    public static let preferred = codex
}

public enum AgentStartupCommandResolver {
    public static func startupCommand(
        defaultAgentCommand: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        wrapperPath: String? = nil
    ) -> String? {
        guard let command = defaultAgentCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              command.isEmpty == false
        else {
            return nil
        }

        let resolvedWrapperPath = wrapperPath?.nilIfBlank
            ?? environment["BALAGAN_AGENT_WRAPPER_PATH"]?.nilIfBlank

        guard let resolvedWrapperPath,
              resolvedWrapperPath.isEmpty == false,
              command == "balagan-agent" || command.hasPrefix("balagan-agent ")
        else {
            return command
        }

        let suffix = command.dropFirst("balagan-agent".count)
        return "\(resolvedWrapperPath.shellQuoted)\(suffix)"
    }

    public static func startupCommand(
        for project: Project,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        wrapperPath: String? = nil
    ) -> String? {
        startupCommand(
            defaultAgentCommand: project.defaultAgentCommand,
            environment: environment,
            wrapperPath: wrapperPath
        )
    }
}
