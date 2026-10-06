import Foundation

/// An agent session a tab ran before its current one: everything needed to resume it (the binding),
/// a title (its first prompt, filled in from the transcript), and when it was replaced.
public struct SessionRecord: Codable, Hashable, Identifiable, Sendable {
    public var binding: ResumeBinding
    public var title: String?
    public var replacedAt: Date

    public init(binding: ResumeBinding, title: String? = nil, replacedAt: Date) {
        self.binding = binding
        self.title = title
        self.replacedAt = replacedAt
    }

    public var id: String { binding.sessionID ?? binding.id }
    public var startedAt: Date { binding.capturedAt ?? binding.createdAt }
}

/// The rules for a tab's session history. Pure: the caller stores the result on the surface.
public enum SessionHistory {
    /// How many earlier sessions a tab keeps.
    public static let limit = 20

    /// When a tab reports `newSessionID`, its current session (if it was a different agent session)
    /// moves to the front of the history. A session already in the history isn't listed twice, and
    /// a session that becomes current again leaves the history.
    public static func archiving(
        current: ResumeBinding?,
        newSessionID: String,
        into history: [SessionRecord],
        at date: Date
    ) -> [SessionRecord] {
        var history = history.filter { $0.binding.sessionID != newSessionID }
        guard let current, current.kind == .agent,
              let currentID = current.sessionID, currentID != newSessionID else {
            return history
        }
        history.removeAll { $0.binding.sessionID == currentID }
        // An archived session's process is gone; never keep its pid, which the OS may reuse.
        var archived = current
        archived.pid = nil
        archived.wasRunning = false
        history.insert(SessionRecord(binding: archived, replacedAt: date), at: 0)
        return Array(history.prefix(limit))
    }

    /// Makes an earlier session current again: it leaves the history, and the session it replaces
    /// goes to the front. Returns nil when there's no such record.
    public static func switching(
        to recordID: SessionRecord.ID,
        current: ResumeBinding?,
        history: [SessionRecord],
        at date: Date
    ) -> (current: ResumeBinding, history: [SessionRecord])? {
        guard let record = history.first(where: { $0.id == recordID }),
              let sessionID = record.binding.sessionID else { return nil }
        let rest = archiving(current: current, newSessionID: sessionID, into: history, at: date)
        var binding = record.binding
        binding.pid = nil
        binding.wasRunning = false
        binding.updatedAt = date
        binding.isStale = false
        binding.autoResume = true
        return (binding, rest)
    }

    /// A session's first prompt, as a one-line title (nil when the transcript has none yet). Reads
    /// only the head of the file: the first prompt is near the top.
    public static func title(transcriptAt path: String, format: AgentTranscriptFormat, maxBytes: Int = 512 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            for entry in AgentTranscriptParser.entries(fromLine: String(line), lineIndex: index, format: format)
            where entry.kind == .user {
                let text = entry.text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.isEmpty == false } ?? ""
                guard text.isEmpty == false else { continue }
                return text.count > 80 ? String(text.prefix(79)) + "…" : text
            }
        }
        return nil
    }
}
