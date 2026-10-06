import Foundation

/// A reusable instruction you send to a task's agent in one click ("Write tests", "Review your diff").
/// Global ones live in the app's preferences; a project can add its own.
public struct SavedPrompt: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var text: String

    public init(id: String = UUID().uuidString, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }

    public var isUsable: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

public enum SavedPrompts {
    /// What a fresh install starts with; editable in Settings → Prompts.
    public static let defaults: [SavedPrompt] = [
        SavedPrompt(
            id: "default-tests",
            title: "Write tests",
            text: "Write tests for the changes you made, covering the edge cases. Run them and fix anything that fails."
        ),
        SavedPrompt(
            id: "default-review",
            title: "Review your diff",
            text: "Review your own changes as a strict code reviewer: look for bugs, missed edge cases and unclear code. Fix what you find, then summarize what you changed."
        ),
        SavedPrompt(
            id: "default-summary",
            title: "Summarize changes",
            text: "Summarize what you changed and why in a few short bullets, so I can review it."
        ),
        SavedPrompt(
            id: "default-commit",
            title: "Commit",
            text: "Commit your changes with a clear commit message. Don't push."
        ),
    ]

    /// The prompts offered for a task: its project's own first, then the global ones (a global prompt
    /// with the same title as a project one is hidden, so a project can override it).
    public static func forTask(project: [SavedPrompt], global: [SavedPrompt]) -> [SavedPrompt] {
        let own = project.filter(\.isUsable)
        let titles = Set(own.map { $0.title.lowercased() })
        return own + global.filter { $0.isUsable && titles.contains($0.title.lowercased()) == false }
    }

    public static func encode(_ prompts: [SavedPrompt]) -> String {
        (try? String(decoding: JSONEncoder().encode(prompts), as: UTF8.self)) ?? "[]"
    }

    /// Decodes a stored list; nil (never saved) gives the defaults, a saved empty list stays empty.
    public static func decode(_ stored: String?) -> [SavedPrompt] {
        guard let stored, let data = stored.data(using: .utf8) else { return defaults }
        return (try? JSONDecoder().decode([SavedPrompt].self, from: data)) ?? defaults
    }
}
