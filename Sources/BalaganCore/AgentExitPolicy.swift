import Foundation

/// What to do when the process in a terminal tab exits.
///
/// A plain shell's tab closes, like any terminal after `exit`. An agent's tab never just disappears:
/// its session is the valuable thing, and closing the tab threw it away. The common way an agent
/// exits on its own is updating itself — Codex (and occasionally Claude Code) offers an update on
/// launch, installs it, and quits — so an agent that exits shortly after starting is resumed in place,
/// with a guard so a crash-on-start can't loop. Any other agent exit (you quit it, it crashed later)
/// leaves the tab with a one-key Resume.
public enum AgentExitPolicy {
    public enum Outcome: Equatable, Sendable {
        /// Plain shell: close the tab.
        case closeTab
        /// Agent exited right after launching (the self-update pattern): resume its session now.
        case resumeAutomatically
        /// Keep the tab and offer Resume (the session is saved).
        case offerResume
        /// Keep the tab and offer to start the agent again (no session to resume).
        case offerRestart
    }

    /// An exit this soon after launch reads as "updated and quit", not "the user was done".
    public static let quickExitWindow: TimeInterval = 90
    /// At most this many automatic resumes per tab within `autoResumeWindow`, so an agent that fails
    /// on every start stops being relaunched and asks instead.
    public static let maxAutoResumes = 2
    public static let autoResumeWindow: TimeInterval = 10 * 60

    public static func outcome(
        isAgentTab: Bool,
        hasSession: Bool,
        launchedAt: Date?,
        now: Date,
        recentAutoResumes: [Date]
    ) -> Outcome {
        guard isAgentTab else { return .closeTab }
        guard hasSession else { return .offerRestart }
        let quickExit = launchedAt.map { now.timeIntervalSince($0) < quickExitWindow } ?? false
        let recent = recentAutoResumes.filter { now.timeIntervalSince($0) < autoResumeWindow }
        if quickExit, recent.count < maxAutoResumes {
            return .resumeAutomatically
        }
        return .offerResume
    }
}
