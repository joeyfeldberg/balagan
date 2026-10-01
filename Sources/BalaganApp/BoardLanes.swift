import Foundation
import BalaganCore

/// Editing a board's lanes (kanban columns). Lanes live on `Project`; mutating `projects`/`tasks`
/// (both `@Published`) drives the autosave, so these don't persist explicitly.
extension BoardViewModel {
    /// Adds a lane to a project's board with a unique id (slugged from the name) and a palette color.
    @discardableResult
    func addLane(toProjectID projectID: Project.ID, name: String) -> Lane? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let trimmed = name.trimmedForStorage
        guard trimmed.isEmpty == false else { return nil }

        let existingIDs = Set(projects[projectIndex].lanes.map(\.id))
        let base = Lane.slug(for: trimmed).nilIfBlank ?? "lane"
        var id = base
        var suffix = 2
        while existingIDs.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        let color = Lane.palette[projects[projectIndex].lanes.count % Lane.palette.count]
        let lane = Lane(id: id, name: trimmed, colorHex: color)
        projects[projectIndex].lanes.append(lane)
        return lane
    }

    /// Collapses a lane to a thin strip, or expands it back.
    func toggleLaneCollapsed(projectID: Project.ID, laneID: Lane.ID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let laneIndex = projects[projectIndex].lanes.firstIndex(where: { $0.id == laneID })
        else {
            return
        }
        projects[projectIndex].lanes[laneIndex].collapsed.toggle()
    }

    func renameLane(projectID: Project.ID, laneID: Lane.ID, to name: String) {
        let trimmed = name.trimmedForStorage
        guard trimmed.isEmpty == false,
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let laneIndex = projects[projectIndex].lanes.firstIndex(where: { $0.id == laneID })
        else {
            return
        }
        projects[projectIndex].lanes[laneIndex].name = trimmed
    }

    /// Moves a lane left (offset -1) or right (offset +1); no-op at the ends.
    func moveLane(projectID: Project.ID, laneID: Lane.ID, by offset: Int) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let laneIndex = projects[projectIndex].lanes.firstIndex(where: { $0.id == laneID })
        else {
            return
        }
        let target = laneIndex + offset
        guard projects[projectIndex].lanes.indices.contains(target) else { return }
        projects[projectIndex].lanes.swapAt(laneIndex, target)
    }

    /// How many tasks currently sit in a lane (archived included, so deletion can never orphan a task).
    func laneTaskCount(projectID: Project.ID, laneID: Lane.ID) -> Int {
        tasks.filter { $0.projectID == projectID && $0.status.rawValue == laneID }.count
    }

    /// Whether a lane can be deleted: it must be empty (move its tasks out first) and not the board's
    /// last column.
    func canDeleteLane(projectID: Project.ID, laneID: Lane.ID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }), project.lanes.count > 1 else {
            return false
        }
        return laneTaskCount(projectID: projectID, laneID: laneID) == 0
    }

    /// Deletes an empty lane. Refuses if it still holds tasks, or if it's the last column. Returns
    /// whether it deleted.
    @discardableResult
    func deleteLane(projectID: Project.ID, laneID: Lane.ID) -> Bool {
        guard canDeleteLane(projectID: projectID, laneID: laneID),
              let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let laneIndex = projects[projectIndex].lanes.firstIndex(where: { $0.id == laneID })
        else {
            return false
        }
        projects[projectIndex].lanes.remove(at: laneIndex)
        return true
    }
}
