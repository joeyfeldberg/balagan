import Foundation

/// An agent's working state, surfaced as the card spinner / sessions-menu icon.
public enum AgentLifecycle: String, Sendable, Equatable {
    case running
    case idle
    case needsInput = "needs-input"
}

/// A task's aggregate agent state, across all its surfaces — the unit the control-socket `state` and
/// `wait` commands report and match on. It's how an orchestrator agent tracks a sub-agent it directed:
/// create the task, then `balagan wait <id> --until idle` until the sub-agent settles.
public enum TaskAgentState: String, Sendable, Equatable, CaseIterable {
    /// At least one of the task's surfaces has an agent actively working.
    case running
    /// An agent is waiting on the user (e.g. a permission prompt) and none are working.
    case needsInput = "needs-input"
    /// An agent is present but settled — not working and not waiting.
    case idle
    /// The task is hibernated; its agents were terminated (see `BoardHibernation`).
    case asleep
    /// No agent in this task (a plain shell, or nothing launched yet).
    case none

    /// Aggregates the per-surface lifecycles into one task-level state. Precedence
    /// running > needs-input > idle: a task with any working surface reads `running`, and only once
    /// nothing is working does a waiting surface make it `needs-input`. `hasAgentSurface` lets a task
    /// whose agent hasn't reported a lifecycle yet still read `idle` rather than `none`.
    public static func aggregate(
        lifecycles: [AgentLifecycle?],
        hasAgentSurface: Bool,
        hibernated: Bool
    ) -> TaskAgentState {
        if hibernated { return .asleep }
        if lifecycles.contains(.running) { return .running }
        if lifecycles.contains(.needsInput) { return .needsInput }
        if lifecycles.contains(.idle) || hasAgentSurface { return .idle }
        return .none
    }

    /// The states `wait` targets when the caller passes no `--until`: the "settled" set an agent lands
    /// in when it's done working (idle) or is asking for something (needs-input).
    public static let defaultSettled: [TaskAgentState] = [.idle, .needsInput]

    /// Parses a `--until` value (comma-separated state names) into the states to wait for. A blank/nil
    /// value yields `defaultSettled`; returns nil if any token isn't a valid state name.
    public static func parseUntil(_ raw: String?) -> [TaskAgentState]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), raw.isEmpty == false else {
            return defaultSettled
        }
        var states: [TaskAgentState] = []
        for token in raw.split(separator: ",") {
            guard let state = TaskAgentState(rawValue: token.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            states.append(state)
        }
        return states.isEmpty ? defaultSettled : states
    }
}

/// Reconciles an agent surface's working state from process liveness.
///
/// The running/idle/needs-input transitions are driven by the agent hooks (mapped by `AgentHookEvent`):
/// `PermissionRequest`→needs-input (immediate, before the dialog), `PostToolUse`→running (resolves an
/// approved prompt), `UserPromptSubmit`/`PreToolUse`→running (except `PreToolUse` for
/// `AskUserQuestion`/`ExitPlanMode`→needs-input), `Stop`→idle, `Notification`→classified by
/// `AgentNotification`. Subagent payloads (`agent_id`) never drive the surface state.
///
/// Beyond clearing a state stranded by a dead process, this reconciler corroborates the hook-driven
/// lifecycle with the terminal-title spinner (`AgentTitleHeuristic`) — the one signal that catches a
/// *missed* hook while the process is still alive (a dropped `Stop` leaving a stuck spinner, a missed
/// prompt-submit that lost "running", an Esc/interrupt, which emits no hook at all). It deliberately
/// does **not** infer state from transcript activity/silence — that was too blunt (a long silent tool
/// looks idle; a resume write looks like new work). The title spinner is different: it's an explicit
/// "working now" flag the agent emits, not a heuristic on file activity. A non-persisted
/// `surfaceLifecycle` still starts clean after a restart.
///
/// The spinner is a *lagging* signal around permission prompts: Claude keeps animating for a few hundred
/// ms after it opens the dialog (title `◐ Bash command execution` → `✳ Bash command execution`), while
/// the `PermissionRequest` hook sets `.needsInput` immediately. So a hook-set `.needsInput` is only
/// overturned once the spinner has been seen on **two consecutive** ticks *after* the hook fired
/// (`titleWorkingStreak`, reset to 0 by the driver whenever a hook writes `.needsInput`). Without that,
/// a tick landing in the lag window would promote to `.running` and the next tick's spinner-absent rule
/// would then demote it to `.idle` — a waiting agent silently reading as finished.
///
/// **Codex is reconciled differently** (`agentKind: .codex`). Our wrapper installs no hooks for Codex,
/// so there is no hook state to corroborate — the title *is* the lifecycle, exactly as herdr does it:
/// spinner ⇒ running, "Action Required" ⇒ needs-input, anything else ⇒ idle. That branch lives here,
/// in the pure reconciler, rather than in the `SET_TITLE` callback for three reasons: the 2 s tick is
/// already the debounce that keeps spinner-frame flicker from flapping the state (the callback fires
/// several times a second); the dead-pid clear and the hibernated-task skip stay in one place; and the
/// whole table is unit-testable without a terminal.
public enum AgentLifecycleReconciler {
    /// The number of consecutive spinner-present ticks needed to overturn a hook-set `.needsInput`.
    /// One tick can still be the pre-dialog lag; two (≥ 2 s apart) means the agent really is working.
    public static let needsInputOverrideStreak = 2

    /// Reconciles a surface whose agent kind is known, routing Codex to the title-derived table and
    /// everything else (Claude, unknown) to the hook-driven path below.
    ///
    /// - Parameters:
    ///   - agentKind: the surface's derived agent (`Surface.agentKind`); nil ⇒ hook-driven path.
    ///   - titleSignal: the latest title reading (`AgentTitleHeuristic.classify`), nil when the surface
    ///     has never set a title.
    public static func reconcile(
        current: AgentLifecycle?,
        processAlive: Bool,
        agentKind: AgentKind?,
        titleSignal: AgentTitleHeuristic.TitleSignal?,
        titleFeatureActive: Bool = false,
        titleWorkingStreak: Int = 0
    ) -> AgentLifecycle? {
        // A dead process can't be running / idle / needing input — clear it, for either agent.
        guard processAlive else { return nil }

        if agentKind == .codex {
            return reconcileCodex(current: current, titleSignal: titleSignal)
        }

        return reconcile(
            current: current,
            processAlive: true,
            // Claude's blocked state comes from its hooks and its title never says "Action Required",
            // so for the hook-driven path anything but a spinner is simply "not working".
            titleWorking: titleSignal.map { $0 == .working },
            titleFeatureActive: titleFeatureActive,
            titleWorkingStreak: titleWorkingStreak
        )
    }

    /// Codex's whole state machine: the title, read once per tick.
    ///
    /// Unlike the Claude path this does **not** gate on `titleFeatureActive` (a "has this surface ever
    /// shown a spinner" latch). That latch exists to stop a missing spinner from demoting a *hook-set*
    /// running state; Codex has no hooks, so there is nothing to protect and a Codex surface that has
    /// only ever shown a plain title is genuinely idle. For the same reason `.needsInput` is **not**
    /// sticky here — it was set by the title, so it clears the moment the title stops saying it (there's
    /// no lagging-spinner race to guard against, because Codex isn't animating while blocked).
    ///
    /// No title yet ⇒ nothing to say; leave whatever is there (a `nil` current stays nil).
    private static func reconcileCodex(
        current: AgentLifecycle?,
        titleSignal: AgentTitleHeuristic.TitleSignal?
    ) -> AgentLifecycle? {
        guard let titleSignal else { return current }
        switch titleSignal {
        case .working: return .running
        case .blocked: return .needsInput
        case .idle: return .idle
        }
    }

    /// - Parameters:
    ///   - current: the surface's current lifecycle (nil = none).
    ///   - processAlive: whether the agent pid is alive (pass `true` when the pid is unknown — absence
    ///     of proof of death must not clear a working agent).
    ///   - titleWorking: the title-spinner reading (true = spinner present, false = absent, nil =
    ///     unknown), or nil when there's no title signal for this surface.
    ///   - titleFeatureActive: whether this surface has shown a spinner at least once. Absence of a
    ///     spinner is only meaningful when true — otherwise the agent may simply not emit one (or the
    ///     user set `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`), and we must not demote a working agent.
    ///   - titleWorkingStreak: consecutive reconcile ticks (including this one) on which the spinner was
    ///     present, counted from the last spinner-absent tick *or* the last hook-set `.needsInput`,
    ///     whichever is later. Only gates the `.needsInput` → `.running` promotion; a lost `.running`
    ///     (current nil / `.idle`) is still recovered on the first observation.
    /// - Returns: the reconciled lifecycle to store (nil = clear).
    public static func reconcile(
        current: AgentLifecycle?,
        processAlive: Bool,
        titleWorking: Bool? = nil,
        titleFeatureActive: Bool = false,
        titleWorkingStreak: Int = 0
    ) -> AgentLifecycle? {
        // A dead process can't be running / idle / needing input — clear it.
        guard processAlive else { return nil }

        // Corroborate with the title spinner, but only for surfaces proven to emit one.
        if titleFeatureActive, let titleWorking {
            if titleWorking {
                // A waiting agent's spinner takes a moment to stop, so one sighting proves nothing —
                // keep `.needsInput` until the spinner has held for two consecutive ticks.
                if current == .needsInput, titleWorkingStreak < needsInputOverrideStreak {
                    return .needsInput
                }
                // Spinner => actively working, whatever the hooks last said (recovers a lost "running").
                return .running
            }
            if current == .running {
                // No spinner but the hooks still say running => a missed Stop (or an Esc/interrupt, which
                // has no hook); clear the stuck spinner. Left as-is for `.needsInput` — a waiting agent
                // legitimately shows no spinner, and its recovery is the hooks + the streak rule above.
                return .idle
            }
        }

        // Otherwise leave the hook-driven state untouched.
        return current
    }
}
