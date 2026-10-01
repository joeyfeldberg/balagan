import Foundation
import SwiftUI
import BalaganCore

struct AttentionDot: View {
    var size: CGFloat = 7
    var color: Color = .accentColor

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: size * 0.55)
            .accessibilityHidden(true)
    }
}

/// What an agent is doing, as one glyph. Resolved with a single precedence — **running > waiting >
/// finished** — so the task card, the sidebar project rows, the terminal tab strip and the titlebar
/// menu can never disagree about what a task is up to.
enum AgentStatusGlyph: String {
    /// Actively working (between prompt-submit and stop).
    case running
    /// Genuinely blocked on a decision (a permission/approval prompt) — it is asking *you* something.
    case waiting
    /// Finished or notified while you weren't looking; clears when you open it.
    case finished

    static func resolve(isRunning: Bool, isWaiting: Bool, needsAttention: Bool) -> AgentStatusGlyph? {
        if isRunning { return .running }
        if isWaiting { return .waiting }
        if needsAttention { return .finished }
        return nil
    }

    var help: String {
        switch self {
        case .running: return "Agent is working"
        case .waiting: return "Waiting for your input"
        case .finished: return "Finished — open to review"
        }
    }
}

/// The shared rendering of `AgentStatusGlyph`: a spinner while working, an amber question mark while
/// waiting on you (it reads as "it's asking you something" — clearer than a coloured light, and it
/// only shows when the agent is genuinely blocked, not merely idle), an accent dot for finished.
struct AgentStatusIndicator: View {
    let glyph: AgentStatusGlyph
    /// Symbol point size. The spinner is boxed to it; the finished dot is drawn at 60% of it.
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch glyph {
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: size, height: size)
            case .waiting:
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Theme.agentWaiting)
            case .finished:
                AttentionDot(size: size * 0.6)
            }
        }
        .help(glyph.help)
        .accessibilityIdentifier("agent-status-\(glyph.rawValue)")
    }
}

struct TerminalHostKey: Hashable, Sendable {
    let taskID: TaskItem.ID
    let surfaceID: Surface.ID

    var rawValue: String {
        "\(taskID)::\(surfaceID)"
    }
}

/// The inputs needed to mount (or resume) a libghostty terminal session on a host view: the session
/// identity, the surface to run, the resolved backend runtime, the appearance, and where host
/// artifacts are written. Threaded as a unit through `LibGhosttyTerminalHostView.configure` /
/// `launchConfirmedResume` and `TerminalHostRegistry.resume`.
struct TerminalSessionConfig {
    let sessionKey: TerminalHostKey
    let surface: Surface
    let runtime: TerminalRuntimeOptions
    let terminalAppearance: TerminalAppearanceSettings
    let artifactDirectory: URL?

    init(
        sessionKey: TerminalHostKey,
        surface: Surface,
        runtime: TerminalRuntimeOptions,
        terminalAppearance: TerminalAppearanceSettings,
        artifactDirectory: URL?
    ) {
        self.sessionKey = sessionKey
        self.surface = surface
        self.runtime = runtime
        self.terminalAppearance = terminalAppearance
        self.artifactDirectory = artifactDirectory
    }

    /// Builds the session key from a task ID + the surface, for call sites that don't already hold one.
    init(
        taskID: TaskItem.ID,
        surface: Surface,
        runtime: TerminalRuntimeOptions,
        terminalAppearance: TerminalAppearanceSettings,
        artifactDirectory: URL?
    ) {
        self.init(
            sessionKey: TerminalHostKey(taskID: taskID, surfaceID: surface.id),
            surface: surface,
            runtime: runtime,
            terminalAppearance: terminalAppearance,
            artifactDirectory: artifactDirectory
        )
    }
}

struct TerminalVisibleTextSnapshot {
    let taskID: TaskItem.ID
    let surfaceID: Surface.ID
    let text: String
}

struct TerminalFontZoomHostResult {
    let taskID: TaskItem.ID
    let surfaceID: Surface.ID
    let handled: Bool
    let beforeSize: LibGhosttySurfaceSize?
    let afterSize: LibGhosttySurfaceSize?

    var artifactPayload: [String: Any] {
        [
            "taskID": taskID,
            "surfaceID": surfaceID,
            "handled": handled,
            "beforeSize": beforeSize?.artifactPayload ?? NSNull(),
            "afterSize": afterSize?.artifactPayload ?? NSNull(),
        ]
    }
}

struct TerminalShortcutContext {
    var newTab: () -> Void
    var closeCurrent: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    var selectTab: (Int) -> Void
    var selectLastTab: () -> Void
    var splitRight: () -> Void
    var splitDown: () -> Void
    var nextSplit: () -> Void
    var previousSplit: () -> Void
    var focusSplit: (SplitFocusDirection) -> Void
    var toggleZoom: () -> Void
    var increaseFontSize: (_ evidenceName: String) -> Void
    var decreaseFontSize: (_ evidenceName: String) -> Void
    var resetFontSize: (_ evidenceName: String) -> Void
}

/// Relative / index-based terminal-tab selection, grouped from the four selection closures that
/// TerminalWorkspace forwards from BoardScreen (next / previous / a specific index / the last).
struct SurfaceSelectionActions {
    var next: () -> Void = {}
    var previous: () -> Void = {}
    var atIndex: (Int) -> Void = { _ in }
    var last: () -> Void = {}
}

/// The terminal font-zoom shortcuts. Each carries an `evidenceName` used by the smoke harness to
/// tag the font-zoom artifact it writes.
struct FontZoomActions {
    var increase: (_ evidenceName: String) -> Void = { _ in }
    var decrease: (_ evidenceName: String) -> Void = { _ in }
    var reset: (_ evidenceName: String) -> Void = { _ in }
}

func safeArtifactComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
}
