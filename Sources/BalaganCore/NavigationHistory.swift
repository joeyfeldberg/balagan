import Foundation

/// A place in the app you can go back to: a board (All Projects or one project's), the Archived view,
/// or a task's workspace.
public enum BoardLocation: Equatable, Hashable, Sendable {
    case board(projectID: String?)
    case archived
    case task(String)
}

/// Browser-style back/forward over the places you've been. Visiting somewhere new drops the forward
/// list. Going back or forward skips places that no longer exist (a deleted task, a removed project)
/// and forgets them, so the buttons never lead to a dead end.
public struct NavigationHistory<Location: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var back: [Location] = []
    public private(set) var current: Location?
    public private(set) var forward: [Location] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }

    /// Records arriving at `location`. Arriving where you already are changes nothing.
    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        if let current {
            back.append(current)
            if back.count > limit { back.removeFirst(back.count - limit) }
        }
        current = location
        forward.removeAll()
    }

    public func canGoBack(where isValid: (Location) -> Bool) -> Bool {
        back.contains(where: isValid)
    }

    public func canGoForward(where isValid: (Location) -> Bool) -> Bool {
        forward.contains(where: isValid)
    }

    /// Steps back to the nearest valid place and returns it, or nil (changing nothing) if there's none.
    public mutating func goBack(where isValid: (Location) -> Bool) -> Location? {
        guard let index = back.lastIndex(where: isValid) else { return nil }
        let target = back[index]
        back.removeSubrange(index...)
        if let current { forward.append(current) }
        current = target
        return target
    }

    /// Steps forward to the nearest valid place and returns it, or nil (changing nothing) if there's none.
    public mutating func goForward(where isValid: (Location) -> Bool) -> Location? {
        guard let index = forward.lastIndex(where: isValid) else { return nil }
        let target = forward[index]
        forward.removeSubrange(index...)
        if let current { back.append(current) }
        current = target
        return target
    }
}
