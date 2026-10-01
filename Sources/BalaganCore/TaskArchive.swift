import Foundation

/// Archive retention math: an archived task is auto-deleted once `retentionDays` have elapsed since it
/// was archived. Pure (no view-model / clock dependency) so it's unit-testable.
extension TaskItem {
    private static let secondsPerDay = 86_400.0

    /// Whole days until this archived task is auto-deleted, rounded up (1 means "tomorrow", 0 or
    /// negative means due/overdue). `nil` when the task isn't archived.
    public func daysUntilAutoDelete(now: Date, retentionDays: Int) -> Int? {
        guard let archivedAt else {
            return nil
        }
        let deadline = archivedAt.addingTimeInterval(Double(retentionDays) * Self.secondsPerDay)
        return Int((deadline.timeIntervalSince(now) / Self.secondsPerDay).rounded(.up))
    }

    /// True when this task is archived and its retention window has fully elapsed (so it should be
    /// auto-deleted).
    public func isArchivedAndExpired(now: Date, retentionDays: Int) -> Bool {
        guard let archivedAt else {
            return false
        }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * Self.secondsPerDay)
        return archivedAt < cutoff
    }
}
