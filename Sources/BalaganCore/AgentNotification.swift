import Foundation

/// Classifies a Claude Code `Notification` hook into the agent working-state it should report.
///
/// The Notification hook fires for many things, only some of which mean "the agent is blocked waiting
/// on you." Critically, the ~60-second `idle_prompt` ("Claude finished and is waiting for your next
/// input") is a *different* `notification_type` from `permission_prompt` (genuinely blocked on your
/// approval). Mapping every notification to `needs-input` — as we used to — flagged a finished, idle
/// agent as "waiting", which is wrong. We classify on the structured `notification_type` field (not the
/// human-readable `message`, whose wording isn't stable) and, for unknown/absent types, report nothing
/// rather than risk a spurious "waiting" indicator.
public enum AgentNotification {
    /// The working-state a `Notification` implies, or `nil` to leave the state unchanged.
    /// - `nil` type or an unrecognized one → `nil` (don't touch the working state).
    public static func lifecycle(forNotificationType type: String?) -> AgentLifecycle? {
        switch type {
        // Genuinely blocked, waiting on a user decision.
        case "permission_prompt",
             "worker_permission_prompt",  // a teammate/worker session asking for approval
             "elicitation_dialog",
             "elicitation_url_dialog",
             "agent_needs_input",
             "quota_auto_resume_stale":   // usage limit reset while asleep; needs a manual Enter
            return .needsInput

        // Not blocked — finished / done / ended.
        case "idle_prompt",
             "agent_completed",
             "quota_auto_resume_disabled":
            return .idle

        // Auto-continued after a usage limit cleared — back to working.
        case "quota_auto_resume_fired":
            return .running

        // Quota auto-resume bookkeeping: an offer/arm/cancel says nothing about whether the agent is
        // working or blocked (only `_fired` / `_stale` / `_disabled` above do). Listed explicitly so a
        // future reader doesn't "helpfully" map them to needs-input.
        case "quota_auto_resume_armed",
             "quota_auto_resume_cancelled",
             "quota_auto_resume_offer":
            return nil

        // Transient or ambiguous (auth, elicitation resolution) and anything we don't recognize: don't
        // touch the working state — let the PermissionRequest/PreToolUse/PostToolUse/Stop hooks drive
        // it instead.
        default:
            return nil
        }
    }
}
