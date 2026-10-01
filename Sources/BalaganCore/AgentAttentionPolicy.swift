import Foundation

/// How an agent lifecycle transition should reach the user: an in-app highlight, a desktop banner,
/// or nothing.
///
/// Pure and unit-tested so the two questions that used to be answered inline — "does this deserve a
/// badge?" and "does this deserve a banner (still, at fire time)?" — have one place to live. The app
/// side (`BoardViewModel.applyAgentAttentionPolicy`) only supplies the current facts and performs the
/// resulting effects.
///
/// Why the app posts these at all: Claude's own OSC banners ("needs your permission", "waiting for
/// your input") are switched off by the injected settings (`preferredNotifChannel:
/// notifications_disabled`), so the lifecycle transitions are the only remaining signal.
public enum AgentAttentionPolicy {
    /// The banner an agent transition earns.
    public enum Banner: Equatable, Sendable {
        /// The agent is blocked on the user. Deliberately *delayed* and re-validated before it fires —
        /// a permission prompt the user answers within a couple of seconds should never buzz.
        case waiting
        /// The agent's turn ended off-screen. Posted immediately: there is nothing left to re-validate.
        case finished
    }

    /// What a transition should trigger.
    public struct Outcome: Equatable, Sendable {
        /// Highlight the surface (tab → task → project) until the user opens it.
        public var flagsAttention: Bool
        /// The banner to post, if any.
        public var banner: Banner?

        public init(flagsAttention: Bool = false, banner: Banner? = nil) {
            self.flagsAttention = flagsAttention
            self.banner = banner
        }

        public static let none = Outcome()
    }

    /// The user's relationship to the surface right now.
    ///
    /// The two are deliberately distinct: `isViewedSurface` (it's the selected tab of the selected
    /// task) gates the in-app highlight, while a banner is suppressed only when the user is *actually
    /// looking* — viewing it **and** Balagan frontmost. Viewing a task with Balagan in the
    /// background still earns a banner (that's the whole point of one).
    public struct Context: Equatable, Sendable {
        public var isViewedSurface: Bool
        public var appIsFrontmost: Bool
        public var isHibernated: Bool
        /// False in `--ui-test-mode` (deterministic snapshots must never post a real banner).
        public var notificationsEnabled: Bool

        public init(
            isViewedSurface: Bool,
            appIsFrontmost: Bool,
            isHibernated: Bool,
            notificationsEnabled: Bool
        ) {
            self.isViewedSurface = isViewedSurface
            self.appIsFrontmost = appIsFrontmost
            self.isHibernated = isHibernated
            self.notificationsEnabled = notificationsEnabled
        }

        /// True only when the user can see the surface *and* is in the app — the one case a banner is
        /// pure noise.
        public var isFocusedSurface: Bool { isViewedSurface && appIsFrontmost }

        /// A hibernated task's agents are terminated and its hosts freed; a late edge must never badge
        /// or buzz for it.
        public var canPostBanner: Bool {
            notificationsEnabled && isHibernated == false && isFocusedSurface == false
        }

        /// Whether a *delayed* waiting banner may be armed at all. Deliberately ignores focus: the
        /// user is almost always looking at the surface when a prompt appears (it's the tab they were
        /// working in), and the question is where they are when the delay runs out — that's judged at
        /// fire time by `canPostBanner`.
        public var canArmWaitingBanner: Bool {
            notificationsEnabled && isHibernated == false
        }
    }

    /// Decides what a `previous → next` lifecycle transition earns.
    ///
    /// Two transitions matter:
    /// - **entering `needsInput`** — the agent is blocked on a decision. Badge it off-screen; arm a
    ///   delayed waiting banner *whatever the focus is right now* (it's re-validated when it fires).
    /// - **`running → idle`** — the turn finished. Badge it off-screen; post a finished banner now.
    public static func evaluate(
        previous: AgentLifecycle?,
        next: AgentLifecycle?,
        context: Context
    ) -> Outcome {
        let enteredNeedsInput = (next == .needsInput && previous != .needsInput)
        let finishedTurn = (previous == .running && next == .idle)
        guard enteredNeedsInput || finishedTurn else { return .none }

        let flags = context.isViewedSurface == false && context.isHibernated == false
        var banner: Banner?
        if enteredNeedsInput, context.canArmWaitingBanner {
            banner = .waiting
        } else if finishedTurn, context.canPostBanner {
            banner = .finished
        }
        return Outcome(flagsAttention: flags, banner: banner)
    }

    /// Whether a surface that is *still* waiting should get its banner armed again because the user
    /// just left it (switched task/tab, or sent Balagan to the background). At most once per waiting
    /// episode — `alreadyPosted` is cleared when the state leaves `needsInput` — so walking away and
    /// back doesn't nag repeatedly.
    public static func shouldRearmWaitingBanner(
        current: AgentLifecycle?,
        alreadyPosted: Bool,
        context: Context
    ) -> Bool {
        current == .needsInput && alreadyPosted == false && context.canPostBanner
    }

    /// Re-validates a *pending* waiting banner at fire time (herdr-style): the agent may have answered
    /// itself, been slept, or the user may have walked over to it in the meantime.
    public static func shouldDeliverWaitingBanner(
        current: AgentLifecycle?,
        context: Context
    ) -> Bool {
        current == .needsInput && context.canPostBanner
    }

    // MARK: - Copy

    /// The agent's name as it reads in a banner ("Claude", "Codex"), falling back to a neutral noun.
    public static func agentDisplayName(_ rawName: String?) -> String {
        guard let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return "The agent"
        }
        switch trimmed.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default:
            if let profile = AgentProfiles.named(trimmed) { return profile.displayName }
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
    }

    /// Banner body for a blocked agent, e.g. "Claude is waiting for your input".
    public static func waitingBody(agentName: String?) -> String {
        "\(agentDisplayName(agentName)) is waiting for your input"
    }

    /// Banner body for a finished turn, e.g. "Claude finished".
    public static func finishedBody(agentName: String?) -> String {
        "\(agentDisplayName(agentName)) finished"
    }
}
