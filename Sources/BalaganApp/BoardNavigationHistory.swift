import Foundation
import BalaganCore

/// Back and forward between the places you've been. Every way of moving (sidebar, cards, ⌘J, the
/// palette, notifications) changes the same three selection properties, so the history records off
/// those instead of hooking each one. A move sets several of them in a row, so recording waits for the
/// run loop to settle and records only where you ended up.
extension BoardViewModel {
    var currentLocation: BoardLocation {
        if showingArchived { return .archived }
        if let selectedTaskID { return .task(selectedTaskID) }
        return .board(projectID: selectedProjectID)
    }

    func scheduleNavigationRecord() {
        guard navigationRecordPending == false else { return }
        navigationRecordPending = true
        DispatchQueue.main.async { [weak self] in
            self?.recordNavigation()
        }
    }

    func recordNavigation() {
        navigationRecordPending = false
        let location = currentLocation
        guard location != navigationHistory.current else { return }
        navigationHistory.visit(location)
    }

    /// Whether a remembered place can still be shown: its task or project hasn't been deleted, and the
    /// task isn't archived.
    func locationExists(_ location: BoardLocation) -> Bool {
        switch location {
        case .archived, .board(projectID: nil):
            return true
        case let .board(projectID?):
            return project(for: projectID) != nil
        case let .task(id):
            return tasks.contains { $0.id == id && $0.isArchived == false }
        }
    }

    var canNavigateBack: Bool {
        navigationHistory.canGoBack(where: locationExists)
    }

    var canNavigateForward: Bool {
        navigationHistory.canGoForward(where: locationExists)
    }

    /// Returns false when there's nowhere to go, so the caller can beep.
    @discardableResult
    func navigateBack() -> Bool {
        recordNavigation()
        guard let target = navigationHistory.goBack(where: locationExists) else { return false }
        show(target)
        return true
    }

    @discardableResult
    func navigateForward() -> Bool {
        recordNavigation()
        guard let target = navigationHistory.goForward(where: locationExists) else { return false }
        show(target)
        return true
    }

    /// Shows a place without recording it as a new visit: the history has already moved there, so the
    /// record that follows finds it current and does nothing.
    private func show(_ location: BoardLocation) {
        switch location {
        case .archived:
            showArchived()
        case .board(projectID: nil):
            showAllProjectTasks()
        case let .board(projectID?):
            showProjectTasks(projectID: projectID)
        case let .task(id):
            if let task = tasks.first(where: { $0.id == id }) { select(task: task) }
        }
    }
}
