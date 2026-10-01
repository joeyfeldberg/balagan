import Foundation

/// The CI state of a single check or of a PR's whole rollup, normalized across GitHub's two check
/// shapes (Actions `CheckRun`s and legacy commit-`StatusContext`s).
public enum CIState: String, Codable, Sendable, Equatable {
    case success
    case failure
    case pending
    case neutral   // completed but not pass/fail (neutral / skipped / stale)
    case noChecks  // no checks at all (named, not `none`, to avoid the Optional.none collision)

    /// Maps a GitHub Actions `CheckRun` (status + conclusion) to a normalized state.
    init(checkRunStatus status: String?, conclusion: String?) {
        // Not COMPLETED yet → still running/queued.
        guard status?.uppercased() == "COMPLETED" else {
            self = .pending
            return
        }
        switch conclusion?.uppercased() {
        case "SUCCESS":
            self = .success
        case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "CANCELLED", "STALE":
            self = .failure
        case "NEUTRAL", "SKIPPED":
            self = .neutral
        default:
            self = .pending
        }
    }

    /// Maps a legacy commit-status `StatusContext` state to a normalized state.
    init(statusContextState state: String?) {
        switch state?.uppercased() {
        case "SUCCESS":
            self = .success
        case "FAILURE", "ERROR":
            self = .failure
        case "PENDING", "EXPECTED":
            self = .pending
        default:
            self = .pending
        }
    }
}

/// One CI check on a PR (a workflow job / an external status).
public struct CICheck: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var state: CIState
    public var url: String?

    public var id: String { "\(name)#\(url ?? "")" }

    public init(name: String, state: CIState, url: String? = nil) {
        self.name = name
        self.state = state
        self.url = url
    }
}

/// A conversation comment on a PR.
public struct PRComment: Codable, Sendable, Equatable, Identifiable {
    public var author: String
    public var body: String
    public var createdAt: String
    public var url: String?

    public var id: String { url ?? "\(author)@\(createdAt)" }

    public init(author: String, body: String, createdAt: String, url: String? = nil) {
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

/// An inline code-review comment — attached to a file + line in the diff (from
/// `GET /pulls/{n}/comments`), distinct from PR conversation comments and review summaries.
public struct PRReviewComment: Codable, Sendable, Equatable, Identifiable {
    public var author: String
    public var body: String
    public var path: String
    public var line: Int?
    public var createdAt: String
    public var url: String?

    public var id: String { url ?? "\(author)@\(createdAt)@\(path)" }

    /// "file.swift:42" (or just the basename when there's no line).
    public var location: String {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        if let line { return "\(file):\(line)" }
        return file
    }

    public init(author: String, body: String, path: String, line: Int?, createdAt: String, url: String? = nil) {
        self.author = author
        self.body = body
        self.path = path
        self.line = line
        self.createdAt = createdAt
        self.url = url
    }
}

/// A review submitted on a PR (carries a state, and an optional summary body).
public struct PRReview: Codable, Sendable, Equatable, Identifiable {
    public var author: String
    /// "APPROVED" / "CHANGES_REQUESTED" / "COMMENTED" / "DISMISSED".
    public var state: String
    public var body: String
    public var submittedAt: String
    public var url: String?

    public var id: String { url ?? "\(author)@\(submittedAt)" }

    public init(author: String, state: String, body: String, submittedAt: String, url: String? = nil) {
        self.author = author
        self.state = state
        self.body = body
        self.submittedAt = submittedAt
        self.url = url
    }
}

/// A pull request associated with a task's branch, plus its CI checks, comments and reviews.
/// Runtime-only (fetched from GitHub via `gh`, never persisted) — mirrors how `surfaceLifecycle` is
/// derived, not stored.
public struct TaskPullRequest: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case open, closed, merged

        init(ghState: String?) {
            switch ghState?.uppercased() {
            case "MERGED": self = .merged
            case "CLOSED": self = .closed
            default: self = .open
            }
        }
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State
    public var isDraft: Bool
    /// GitHub review decision: "APPROVED" / "CHANGES_REQUESTED" / "REVIEW_REQUIRED" / nil.
    public var reviewDecision: String?
    public var checks: [CICheck]
    public var comments: [PRComment]
    public var reviews: [PRReview]
    public var reviewComments: [PRReviewComment]

    public init(
        number: Int,
        title: String,
        url: String,
        state: State,
        isDraft: Bool,
        reviewDecision: String?,
        checks: [CICheck],
        comments: [PRComment] = [],
        reviews: [PRReview] = [],
        reviewComments: [PRReviewComment] = []
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.comments = comments
        self.reviews = reviews
        self.reviewComments = reviewComments
    }

    /// Comment count shown in the UI: conversation comments, inline code-review comments, and reviews
    /// that carry a written body (a bare "approved" with no text isn't counted as a comment).
    public var commentCount: Int {
        comments.count + reviewComments.count + reviews.filter { $0.body.isEmpty == false }.count
    }

    /// Overall CI state, mirroring GitHub's own precedence: any failure ⇒ failure; else any pending ⇒
    /// pending; else if there are passing checks ⇒ success; else (only neutral/skipped, or none) ⇒
    /// none. Neutral/skipped never block a "success".
    public var rollup: CIState {
        if checks.isEmpty { return .noChecks }
        if checks.contains(where: { $0.state == .failure }) { return .failure }
        if checks.contains(where: { $0.state == .pending }) { return .pending }
        if checks.contains(where: { $0.state == .success }) { return .success }
        return .noChecks
    }

    public var passedCount: Int { checks.filter { $0.state == .success }.count }
    public var failedCount: Int { checks.filter { $0.state == .failure }.count }
    public var pendingCount: Int { checks.filter { $0.state == .pending }.count }
}
