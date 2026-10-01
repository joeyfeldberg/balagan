import Foundation

public enum PRAuthor {
    private static let knownBotLogins: Set<String> = [
        "github-actions", "dependabot", "renovate", "codecov", "sonarcloud",
        "sonarqubecloud", "coderabbitai", "vercel", "netlify", "sentry-io", "changeset-bot",
    ]
    private static let knownBotPrefixes = ["copilot", "dependabot", "renovate"]

    /// Whether a login is a bot. GitHub Apps canonically end in `[bot]`, but `gh` sometimes strips
    /// that, so we also match known logins/prefixes and a `-bot`/`bot` fallback.
    public static func isBot(_ login: String) -> Bool {
        let name = login.lowercased()
        if name.hasSuffix("[bot]") { return true }
        if knownBotLogins.contains(name) { return true }
        if knownBotPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return name.hasSuffix("-bot") || name.hasSuffix("bot")
    }
}

/// A short relative time ("2d ago", "just now") from an ISO-8601 timestamp. `relativeTo` is injectable
/// so it's deterministically testable. Returns "" for an empty/unparseable timestamp.
public func relativePRTime(fromISO iso: String, relativeTo now: Date) -> String {
    guard iso.isEmpty == false, let date = parseISO8601(iso) else {
        return ""
    }
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    let days = hours / 24
    if days < 7 { return "\(days)d ago" }
    let weeks = days / 7
    if weeks < 5 { return "\(weeks)w ago" }
    let months = days / 30
    if months < 12 { return "\(months)mo ago" }
    return "\(days / 365)y ago"
}

/// Parses GitHub's ISO-8601 timestamps (with or without fractional seconds). Formatters are built
/// locally — `ISO8601DateFormatter` isn't `Sendable`, so it can't be a shared global under Swift 6.
private func parseISO8601(_ iso: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: iso) { return date }
    return ISO8601DateFormatter().date(from: iso)
}

/// One item in a PR's merged activity timeline (a comment or a review), with the bot flag resolved.
public struct PRActivityItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case comment
        case review(state: String)
        /// An inline code-review comment, with its file location ("file.swift:42").
        case codeComment(location: String)
    }

    public var author: String
    public var isBot: Bool
    public var body: String
    public var timestamp: String   // ISO-8601
    public var url: String?
    public var kind: Kind

    public var id: String { url ?? "\(author)@\(timestamp)" }

    /// The review state ("APPROVED" / "CHANGES_REQUESTED" / …) if this is a review, else nil.
    public var reviewState: String? {
        if case let .review(state) = kind { return state }
        return nil
    }

    /// The code location ("file.swift:42") if this is an inline code comment, else nil.
    public var codeLocation: String? {
        if case let .codeComment(location) = kind { return location }
        return nil
    }
}

extension TaskPullRequest {
    /// Comments + reviews merged into one timeline, oldest → newest (how a conversation reads).
    public var activity: [PRActivityItem] {
        let commentItems = comments.map {
            PRActivityItem(author: $0.author, isBot: PRAuthor.isBot($0.author), body: $0.body,
                           timestamp: $0.createdAt, url: $0.url, kind: .comment)
        }
        let reviewItems = reviews.map {
            PRActivityItem(author: $0.author, isBot: PRAuthor.isBot($0.author), body: $0.body,
                           timestamp: $0.submittedAt, url: $0.url, kind: .review(state: $0.state))
        }
        let codeItems = reviewComments.map {
            PRActivityItem(author: $0.author, isBot: PRAuthor.isBot($0.author), body: $0.body,
                           timestamp: $0.createdAt, url: $0.url, kind: .codeComment(location: $0.location))
        }
        return (commentItems + reviewItems + codeItems).sorted { $0.timestamp < $1.timestamp }
    }
}
