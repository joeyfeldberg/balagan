import Foundation

/// Passive, screen-free reading of an agent's working state from its **terminal title**.
///
/// Claude Code and Codex prefix the OSC 0/2 title with an animated spinner glyph while the agent is
/// actively working, and drop it when it isn't (Claude then shows `✳ <summary>`). The glyph set differs
/// per agent — and changed under us:
/// - **Claude Code ≥ 2.1.228** animates the half-circles `◐◑◒◓` (U+25D0–U+25D3). Older builds used
///   Braille, so matching Braille alone silently stopped detecting current Claude.
/// - **Codex** still animates Braille `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` (U+2800–U+28FF).
///
/// We already receive title changes via the libghostty `SET_TITLE` callback, so this is a free
/// corroboration signal for the hook-driven `AgentLifecycle` — no `ghostty_surface_read_text` (which
/// leaks). It is best-effort: the spinner can be turned off (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`) and
/// not every agent emits one, so callers must treat *absence* of a spinner as meaningful only for
/// surfaces that have shown one before. Absence is also ambiguous *while* an agent is up: Claude stops
/// the spinner while a permission dialog is open, so "no spinner" means idle **or** blocked (see
/// `AgentLifecycleReconciler`).
///
/// **Codex is the exception**: it has no hooks in our wrapper, so the title isn't corroboration — it's
/// the *only* working-state signal there is. Codex also names its blocked state in the title
/// ("Action Required …"), which Claude never does, so `classify` reads the three states directly.
public enum AgentTitleHeuristic {
    /// What a terminal title says about the agent's working state.
    public enum TitleSignal: String, Sendable, Equatable, CaseIterable {
        /// A spinner glyph leads the title — the agent is working right now.
        case working
        /// The title says "Action Required" — the agent is waiting on the user (Codex's approval /
        /// question state). Claude never writes this; its blocked state comes from the hooks.
        case blocked
        /// A non-blank title with neither marker — the agent is settled.
        case idle
    }

    /// Braille (Codex) and the quadrant half-circles (Claude Code ≥ 2.1.228).
    private static let spinnerRanges: [ClosedRange<UInt32>] = [0x2800...0x28FF, 0x25D0...0x25D3]

    /// The phrase Codex puts in the title while it blocks on the user (an approval prompt or a
    /// question). Matched case-insensitively, anywhere in the title — Codex prefixes it, but the
    /// surrounding decoration varies by version.
    private static let blockedMarker = "Action Required"

    private static func isSpinnerScalar(_ scalar: Unicode.Scalar) -> Bool {
        spinnerRanges.contains { $0.contains(scalar.value) }
    }

    /// Reads a title as one of the three working states, or `nil` when the title carries no information
    /// (blank/absent — a surface that hasn't set a title yet must not be read as idle).
    ///
    /// Precedence is spinner-first: an animating agent is working even if the previous prompt's text is
    /// still in the title.
    public static func classify(title: String?) -> TitleSignal? {
        guard let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        if isWorking(title: title) {
            return .working
        }
        if title.range(of: blockedMarker, options: [.caseInsensitive]) != nil {
            return .blocked
        }
        return .idle
    }

    /// Whether the title's first non-space character is a spinner glyph — i.e. the agent is actively
    /// working right now. `✳ <summary>` (Claude's not-working title) is not a spinner.
    public static func isWorking(title: String) -> Bool {
        let trimmed = title.drop(while: { $0 == " " })
        guard let first = trimmed.unicodeScalars.first else { return false }
        return isSpinnerScalar(first)
    }

    /// The title with a leading spinner glyph (and the spaces around it) removed, so the displayed tab
    /// label is stable while the agent works — the animated glyph would otherwise churn the title ~10×/s
    /// (a model mutation each time) and make tabs flicker. Titles without a spinner are returned as-is.
    public static func strippingSpinner(_ title: String) -> String {
        let withoutLeadingSpaces = String(title.drop(while: { $0 == " " }))
        guard let first = withoutLeadingSpaces.unicodeScalars.first, isSpinnerScalar(first) else {
            return title
        }
        return String(withoutLeadingSpaces.dropFirst().drop(while: { $0 == " " }))
    }
}
