import AppKit
import BalaganCore

/// Review comments on a task's diff (Changes view): drafted line by line, kept on the task until
/// sent, then delivered to the task's agent as one pasted message. The message itself is the pure
/// `ReviewMessage` (Core).
extension BoardViewModel {
    func reviewComments(taskID: TaskItem.ID) -> [DiffComment] {
        tasks.first { $0.id == taskID }?.reviewComments ?? []
    }

    func addReviewComment(taskID: TaskItem.ID, path: String, line: DiffLine, body: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let anchor = DiffComment.anchor(for: line),
              body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        let comment = DiffComment(path: path, side: anchor.side, line: anchor.line, lineText: line.text, body: body)
        tasks[index].reviewComments = (tasks[index].reviewComments ?? []) + [comment]
    }

    func updateReviewComment(taskID: TaskItem.ID, commentID: DiffComment.ID, body: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let commentIndex = tasks[index].reviewComments?.firstIndex(where: { $0.id == commentID }) else { return }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tasks[index].reviewComments?.remove(at: commentIndex)
        } else {
            tasks[index].reviewComments?[commentIndex].body = body
        }
    }

    func deleteReviewComment(taskID: TaskItem.ID, commentID: DiffComment.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].reviewComments?.removeAll { $0.id == commentID }
    }

    func discardReviewComments(taskID: TaskItem.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].reviewComments = nil
    }

    /// The agent tab a review goes to: the selected tab if it's an agent, otherwise the task's first
    /// agent tab that has a live terminal.
    func reviewTargetSurface(taskID: TaskItem.ID) -> Surface.ID? {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return nil }
        let live = task.workspace.surfaces.map(\.id).filter {
            surfaceIsAgentTerminal(taskID: taskID, surfaceID: $0)
                && TerminalHostRegistry.shared.existingHost(taskID: taskID, surfaceID: $0)?.surfaceHandle != nil
        }
        if let selected = task.workspace.selectedSurfaceID, live.contains(selected) { return selected }
        return live.first
    }

    /// Why text can't be sent to the task's agent right now, or nil when it can.
    func agentSendBlocker(taskID: TaskItem.ID) -> String? {
        guard let surfaceID = reviewTargetSurface(taskID: taskID) else {
            return "No agent is running in this task. Start one in the Terminal view first."
        }
        if surfaceLifecycle[hostKey(taskID, surfaceID)] == .needsInput {
            return "The agent is waiting on a prompt. Answer it first, so this doesn't land in the prompt."
        }
        return nil
    }

    /// Why a review can't be sent right now, or nil when it can.
    func reviewSendBlocker(taskID: TaskItem.ID) -> String? {
        guard reviewComments(taskID: taskID).isEmpty == false else { return "No comments yet" }
        return agentSendBlocker(taskID: taskID)
    }

    /// Pastes text into the task's agent as one message and submits it, then shows that terminal.
    /// The paste goes through Ghostty's text input, which wraps it as a bracketed paste, so the
    /// agent's input box receives it whole instead of submitting at each newline.
    @discardableResult
    func sendToAgent(taskID: TaskItem.ID, text: String) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isEmpty == false,
              agentSendBlocker(taskID: taskID) == nil,
              let surfaceID = reviewTargetSurface(taskID: taskID),
              let handle = TerminalHostRegistry.shared.existingHost(taskID: taskID, surfaceID: surfaceID)?.surfaceHandle
        else { return false }
        handle.sendText(message)
        // Give the agent's TUI a beat to take the paste before the Enter that submits it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            handle.sendEnterKey()
        }
        showingChangesView = false
        showingReaderMode = false
        select(surfaceID: surfaceID, forTaskID: taskID)
        return true
    }

    /// Sends the task's pending diff comments as one review message, then clears them.
    @discardableResult
    func sendReviewComments(taskID: TaskItem.ID) -> Bool {
        guard reviewSendBlocker(taskID: taskID) == nil else { return false }
        let fileOrder: [String] = {
            if case .loaded(let changes)? = taskChanges[taskID] { return changes.files.map(\.path) }
            return []
        }()
        let message = ReviewMessage.compose(reviewComments(taskID: taskID), fileOrder: fileOrder)
        guard sendToAgent(taskID: taskID, text: message) else { return false }
        discardReviewComments(taskID: taskID)
        return true
    }

    // MARK: - Saved prompts

    /// The prompts offered for a task: its project's own, then the global ones from Settings.
    func savedPrompts(for task: TaskItem) -> [SavedPrompt] {
        SavedPrompts.forTask(
            project: project(for: task.projectID)?.savedPrompts ?? [],
            global: SavedPrompts.decode(UserDefaults.standard.string(forKey: AppPreferences.Keys.savedPrompts))
        )
    }
}
