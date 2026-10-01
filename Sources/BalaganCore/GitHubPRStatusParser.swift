import Foundation

/// Parses `gh` JSON into a `TaskPullRequest`. Pure and Foundation-only (JSONSerialization) so it's
/// fully unit-testable without a network or the `gh` binary. Tolerant of missing fields and of the
/// two GitHub check shapes (`CheckRun` from Actions, `StatusContext` from legacy commit statuses).
public enum GitHubPRStatusParser {
    /// The `--json` field set to request from `gh pr view`.
    public static let ghViewFields =
        "number,title,url,state,isDraft,reviewDecision,statusCheckRollup,comments,reviews"

    /// Parses the object emitted by `gh pr view <branch> --json \(ghViewFields)`.
    public static func pullRequest(fromViewJSON data: Data) -> TaskPullRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return pullRequest(from: object)
    }

    /// Parses the array emitted by `gh pr list --head <branch> --json \(ghViewFields)`, returning the
    /// first open PR (else the first PR), or nil if the list is empty.
    public static func firstPullRequest(fromListJSON data: Data) -> TaskPullRequest? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let prs = array.compactMap(pullRequest(from:))
        return prs.first(where: { $0.state == .open }) ?? prs.first
    }

    static func pullRequest(from object: [String: Any]) -> TaskPullRequest? {
        guard let number = object["number"] as? Int,
              let url = object["url"] as? String
        else {
            return nil
        }

        let checks = (object["statusCheckRollup"] as? [[String: Any]] ?? []).compactMap(check(from:))
        let comments = (object["comments"] as? [[String: Any]] ?? []).compactMap(comment(from:))
        let reviews = (object["reviews"] as? [[String: Any]] ?? []).compactMap(review(from:))

        return TaskPullRequest(
            number: number,
            title: object["title"] as? String ?? "",
            url: url,
            state: TaskPullRequest.State(ghState: object["state"] as? String),
            isDraft: object["isDraft"] as? Bool ?? false,
            reviewDecision: (object["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            checks: checks,
            comments: comments,
            reviews: reviews
        )
    }

    static func check(from object: [String: Any]) -> CICheck? {
        if (object["__typename"] as? String) == "StatusContext" {
            guard let context = object["context"] as? String else { return nil }
            return CICheck(
                name: context,
                state: CIState(statusContextState: object["state"] as? String),
                url: object["targetUrl"] as? String
            )
        }
        // CheckRun (the common Actions case), or an unknown shape carrying a name.
        guard let name = object["name"] as? String, name.isEmpty == false else { return nil }
        return CICheck(
            name: name,
            state: CIState(checkRunStatus: object["status"] as? String, conclusion: object["conclusion"] as? String),
            url: object["detailsUrl"] as? String
        )
    }

    static func comment(from object: [String: Any]) -> PRComment? {
        let body = object["body"] as? String ?? ""
        guard body.isEmpty == false else { return nil }
        return PRComment(
            author: authorLogin(object["author"]),
            body: body,
            createdAt: object["createdAt"] as? String ?? "",
            url: object["url"] as? String
        )
    }

    /// Parses the array from `gh api repos/{owner}/{repo}/pulls/{n}/comments` (inline code comments).
    public static func reviewComments(fromAPIJSON data: Data) -> [PRReviewComment] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap(reviewComment(from:))
    }

    static func reviewComment(from object: [String: Any]) -> PRReviewComment? {
        let body = object["body"] as? String ?? ""
        guard body.isEmpty == false, let path = object["path"] as? String else { return nil }
        // `line` is the current line; fall back to `original_line` for outdated comments.
        let line = object["line"] as? Int ?? object["original_line"] as? Int
        return PRReviewComment(
            author: authorLogin(object["user"]),   // REST uses `user`, not `author`
            body: body,
            path: path,
            line: line,
            createdAt: object["created_at"] as? String ?? "",
            url: object["html_url"] as? String
        )
    }

    static func review(from object: [String: Any]) -> PRReview? {
        let state = object["state"] as? String ?? ""
        let body = object["body"] as? String ?? ""
        // Drop empty "COMMENTED" reviews (GitHub emits one per inline-comment batch with no summary).
        guard state.isEmpty == false, !(state.uppercased() == "COMMENTED" && body.isEmpty) else {
            return nil
        }
        return PRReview(
            author: authorLogin(object["author"]),
            state: state,
            body: body,
            submittedAt: object["submittedAt"] as? String ?? "",
            url: object["url"] as? String
        )
    }

    /// `gh` nests the author as `{"login": "...", ...}`; fall back to a bare string or "unknown".
    private static func authorLogin(_ value: Any?) -> String {
        if let dict = value as? [String: Any], let login = dict["login"] as? String, login.isEmpty == false {
            return login
        }
        if let string = value as? String, string.isEmpty == false {
            return string
        }
        return "unknown"
    }
}
