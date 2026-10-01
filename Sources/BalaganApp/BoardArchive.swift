import Foundation
import BalaganCore

/// Archiving and retention: moving tasks off the board, restoring them, and pruning ones whose
/// retention window has elapsed. Extracted from `BoardCRUD`.
extension BoardViewModel {
    /// Archived tasks are hidden from the board and auto-deleted after this many days.
    static let archivedTaskRetentionDays = 30

    /// Archives a task: removes it from the board and starts the retention clock. If it's the open
    /// task, returns to the board.
    func archiveTask(id taskID: TaskItem.ID, at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        tasks[index].archivedAt = date
        tasks[index].updatedAt = date
        if selectedTaskID == taskID {
            selectedTaskID = nil
            selectedWorkspaceID = nil
            selectedSurfaceID = nil
        }
    }

    /// Restores an archived task back onto the board.
    func unarchiveTask(id taskID: TaskItem.ID, at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        tasks[index].archivedAt = nil
        tasks[index].updatedAt = date
    }

    /// Days until an archived task is auto-deleted (negative once overdue); nil if not archived.
    func daysUntilAutoDelete(_ task: TaskItem, now: Date = Date()) -> Int? {
        task.daysUntilAutoDelete(now: now, retentionDays: Self.archivedTaskRetentionDays)
    }

    /// Permanently deletes archived tasks whose retention window has elapsed. Only removes the board
    /// record — never touches git branches or worktrees (those may hold unpushed work). Returns the
    /// deleted task IDs. Called on launch.
    @discardableResult
    func pruneExpiredArchivedTasks(
        now: Date = Date(),
        retentionDays: Int = BoardViewModel.archivedTaskRetentionDays
    ) -> [TaskItem.ID] {
        let expiredIDs = tasks
            .filter { $0.isArchivedAndExpired(now: now, retentionDays: retentionDays) }
            .map(\.id)
        for taskID in expiredIDs {
            deleteTask(id: taskID)
        }
        return expiredIDs
    }
}
