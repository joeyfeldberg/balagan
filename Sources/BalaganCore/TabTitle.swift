import Foundation

/// The name a terminal tab shows in the task header.
public enum TabTitle {
    /// A tab whose title only repeats its task's title (agents often name their terminal after the
    /// task) shows what runs in it instead, because the header already shows the task. Any other title,
    /// such as an agent's own summary or a shell's folder, is kept as it is.
    public static func display(title: String, taskTitle: String, agentName: String?) -> String {
        let fallback = agentName?.nilIfBlank ?? "Terminal"
        let core = bare(title)
        guard core.isEmpty == false else { return fallback }
        return core.caseInsensitiveCompare(bare(taskTitle)) == .orderedSame ? fallback : title
    }

    /// The short name for an agent in a tab: "Claude" rather than "Claude Code".
    public static func agentName(_ displayName: String?) -> String? {
        displayName?.replacingOccurrences(of: " Code", with: "").nilIfBlank
    }

    /// A title without its working spinner or Claude's `✳` marker, trimmed.
    private static func bare(_ title: String) -> String {
        var text = AgentTitleHeuristic.strippingSpinner(title).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("✳") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
