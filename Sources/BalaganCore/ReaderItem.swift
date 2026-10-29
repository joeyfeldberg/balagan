/// What the reader actually lays out: assistant prose is the star, user prompts stay visible, and
/// runs of tool calls / thinking collapse into one expandable activity row.
public enum ReaderItem: Identifiable, Equatable, Sendable {
    case prose(TranscriptEntry)
    case user(TranscriptEntry)
    case activity([TranscriptEntry])

    public var id: String {
        switch self {
        case let .prose(entry): return "prose-\(entry.id)"
        case let .user(entry): return "user-\(entry.id)"
        case let .activity(entries): return "activity-\(entries.first?.id ?? "?")"
        }
    }

    public var isProse: Bool {
        if case .prose = self { return true }
        return false
    }

    /// Groups a transcript for display, folding each run of tool calls and thinking into one item.
    public static func grouping(_ entries: [TranscriptEntry]) -> [ReaderItem] {
        var items: [ReaderItem] = []
        var activityRun: [TranscriptEntry] = []
        func flushActivity() {
            if activityRun.isEmpty == false {
                items.append(.activity(activityRun))
                activityRun = []
            }
        }
        for entry in entries {
            switch entry.kind {
            case .assistant:
                flushActivity()
                items.append(.prose(entry))
            case .user:
                flushActivity()
                items.append(.user(entry))
            case .toolUse, .thinking:
                activityRun.append(entry)
            }
        }
        flushActivity()
        return items
    }
}
