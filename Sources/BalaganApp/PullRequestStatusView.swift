import AppKit
import SwiftUI
import BalaganCore

/// Shared icon/color for a CI state, used by both the card badge and the header popover so they read
/// consistently.
enum CIStatusStyle {
    static func symbol(_ state: CIState) -> String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        case .neutral: return "minus.circle.fill"
        case .noChecks: return "circle.dashed"
        }
    }

    static func color(_ state: CIState) -> Color {
        switch state {
        case .success: return Color(red: 0.25, green: 0.73, blue: 0.44)
        case .failure: return Color(red: 0.88, green: 0.36, blue: 0.36)
        case .pending: return Color(red: 0.90, green: 0.68, blue: 0.24)
        case .neutral, .noChecks: return Theme.textTertiary
        }
    }

    static func label(_ state: CIState) -> String {
        switch state {
        case .success: return "Checks passing"
        case .failure: return "Checks failing"
        case .pending: return "Checks running"
        case .neutral: return "Checks neutral"
        case .noChecks: return "No checks"
        }
    }
}

/// Compact PR/CI chip shown on a task card: rollup icon + PR number, plus draft/merged and a comment
/// count. Glanceable only — the detail lives in the header popover.
struct TaskCardPRBadge: View {
    let pullRequest: TaskPullRequest
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: CIStatusStyle.symbol(pullRequest.rollup))
                .foregroundStyle(CIStatusStyle.color(pullRequest.rollup))
            Text("#\(pullRequest.number)")
                .foregroundStyle(Theme.textSecondary)
            if pullRequest.state == .merged {
                Text("merged").foregroundStyle(Color(red: 0.63, green: 0.46, blue: 0.86))
            } else if pullRequest.isDraft {
                Text("draft").foregroundStyle(Theme.textTertiary)
            }
            if pullRequest.commentCount > 0 {
                Image(systemName: "text.bubble")
                    .foregroundStyle(Theme.textTertiary)
                Text("\(pullRequest.commentCount)")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: Theme.TextSize.micro * scale, weight: .medium))
        .help("PR #\(pullRequest.number): \(CIStatusStyle.label(pullRequest.rollup))")
    }
}

/// Header control: a button summarizing the PR's CI rollup that opens a popover with the full checks
/// list, comments and reviews, plus refresh / open-in-browser.
struct PullRequestHeaderButton: View {
    let pullRequest: TaskPullRequest?
    let isRefreshing: Bool
    let unavailableReason: String?
    let onRefresh: () -> Void
    var scale: CGFloat = 1
    @State private var showingDetail = false

    var body: some View {
        Button {
            if pullRequest != nil { showingDetail.toggle() } else { onRefresh() }
        } label: {
            HStack(spacing: 4 * scale) {
                if isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                        .frame(width: 12 * scale, height: 12 * scale)
                } else if let pullRequest {
                    Image(systemName: CIStatusStyle.symbol(pullRequest.rollup))
                        .foregroundStyle(CIStatusStyle.color(pullRequest.rollup))
                } else {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.textTertiary)
                }
                if let pullRequest {
                    Text("#\(pullRequest.number)")
                } else {
                    Text("PR")
                }
            }
            .font(.system(size: Theme.TextSize.body * scale, weight: .medium))
        }
        .buttonStyle(.bordered)
        .help(helpText)
        .accessibilityIdentifier("pull-request-status-button")
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            if let pullRequest {
                PullRequestPopover(pullRequest: pullRequest, isRefreshing: isRefreshing, onRefresh: onRefresh)
            }
        }
    }

    private var helpText: String {
        if let reason = unavailableReason { return reason }
        guard let pullRequest else { return "No pull request for this branch (click to refresh)" }
        return "PR #\(pullRequest.number): \(CIStatusStyle.label(pullRequest.rollup))"
    }
}

/// The PR detail panel: title/state header, each CI check, and the comments + reviews thread.
struct PullRequestPopover: View {
    let pullRequest: TaskPullRequest
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    checksSection
                    if pullRequest.activity.isEmpty == false {
                        activitySection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)
        }
        .padding(14)
        .frame(width: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: CIStatusStyle.symbol(pullRequest.rollup))
                    .foregroundStyle(CIStatusStyle.color(pullRequest.rollup))
                Text("#\(pullRequest.number)").fontWeight(.semibold)
                statePill
                Spacer()
                Button { onRefresh() } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .accessibilityIdentifier("pull-request-refresh-button")
                Button { open(pullRequest.url) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open PR in browser")
            }
            Text(pullRequest.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            if let decision = reviewDecisionLabel {
                Text(decision).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var statePill: some View {
        let (text, color): (String, Color) = {
            switch pullRequest.state {
            case .merged: return ("Merged", Color(red: 0.63, green: 0.46, blue: 0.86))
            case .closed: return ("Closed", Color(red: 0.88, green: 0.36, blue: 0.36))
            case .open: return pullRequest.isDraft
                ? ("Draft", Theme.textTertiary)
                : ("Open", Color(red: 0.25, green: 0.73, blue: 0.44))
            }
        }()
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHECKS").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
            if pullRequest.checks.isEmpty {
                Text("No checks reported.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(pullRequest.checks) { check in
                    Button { if let url = check.url { open(url) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: CIStatusStyle.symbol(check.state))
                                .foregroundStyle(CIStatusStyle.color(check.state))
                                .font(.system(size: 11))
                            Text(check.name).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if check.url != nil {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(check.url == nil)
                }
            }
        }
    }

    private var activitySection: some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 8) {
            Text("CONVERSATION").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
            ForEach(pullRequest.activity) { item in
                PRActivityCard(item: item, now: now)
            }
        }
    }

    private var reviewDecisionLabel: String? {
        switch pullRequest.reviewDecision?.uppercased() {
        case "APPROVED": return "Review: approved"
        case "CHANGES_REQUESTED": return "Review: changes requested"
        case "REVIEW_REQUIRED": return "Review: required"
        default: return nil
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One comment/review in the PR conversation, as a card: state-tinted accent bar, author (humans
/// bold, bots dimmed + collapsed), review-state pill, relative time, and a rendered-markdown body.
private struct PRActivityCard: View {
    let item: PRActivityItem
    let now: Date
    @State private var expanded: Bool

    init(item: PRActivityItem, now: Date) {
        self.item = item
        self.now = now
        // Collapse only bot *summaries/conversation* (noise). Inline code comments are the signal —
        // never collapse them, even from Copilot. Humans always start expanded.
        let collapsible = item.isBot && item.codeLocation == nil
        _expanded = State(initialValue: collapsible == false)
    }

    /// Only bot summary/conversation cards collapse; humans and inline code comments never do.
    private var isCollapsible: Bool { item.isBot && item.codeLocation == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1).fill(accentColor).frame(width: 2)
            VStack(alignment: .leading, spacing: 5) {
                headerRow
                if isCollapsible && expanded == false {
                    Text(PRCommentMarkdown.synopsis(from: item.body))
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                } else {
                    MarkdownBlockView(blocks: PRCommentMarkdown.blocks(from: bodyForDisplay))
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, 9)
            .padding(.vertical, 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(item.isBot ? Theme.surface : Theme.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if item.isBot { Text("🤖").font(.system(size: 11)) }
            Text(item.author)
                .font(.system(size: 11.5, weight: item.isBot ? .medium : .semibold))
                .foregroundStyle(item.isBot ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
            if let state = item.reviewState { reviewStatePill(state) }
            if let location = item.codeLocation { codeLocationChip(location) }
            Text(relativePRTime(fromISO: item.timestamp, relativeTo: now))
                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 4)
            if isCollapsible {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                .help(expanded ? "Collapse" : "Expand")
            }
            if let url = item.url {
                Button { NSWorkspace.shared.open(URL(string: url) ?? URL(fileURLWithPath: "/")) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                .help("Open in browser")
            }
        }
    }

    @ViewBuilder
    private func reviewStatePill(_ state: String) -> some View {
        let text = state.replacingOccurrences(of: "_", with: " ").lowercased()
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(accentColor)
    }

    /// The "file.swift:42" chip on an inline code comment.
    private func codeLocationChip(_ location: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 8))
            Text(location).font(.system(size: 9.5, design: .monospaced))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// A bot's body, minus the leading empty-review "(no summary)" noise.
    private var bodyForDisplay: String {
        if item.body.isEmpty, item.reviewState != nil { return "_(no summary)_" }
        return item.body
    }

    private var accentColor: Color {
        if item.codeLocation != nil { return Color(red: 0.42, green: 0.55, blue: 0.86) }  // code = blue
        switch item.reviewState?.uppercased() {
        case "APPROVED": return Color(red: 0.25, green: 0.73, blue: 0.44)
        case "CHANGES_REQUESTED", "DISMISSED": return Color(red: 0.88, green: 0.36, blue: 0.36)
        default: return item.isBot ? Color.clear : Theme.textTertiary.opacity(0.5)
        }
    }
}

extension TaskPullRequest {
    /// Representative PR for the headless popover snapshot (`BALAGAN_SHOW_PR_POPOVER=1`): a human
    /// comment with markdown, plus a bot review + bot comment (overview + coverage table) that should
    /// collapse. Never used in normal runs.
    static var snapshotSample: TaskPullRequest {
        TaskPullRequest(
            number: 4160,
            title: "feat(agent): expose cart state via a Librarian cart_lookup",
            url: "https://github.com/example/repo/pull/4160",
            state: .open,
            isDraft: false,
            reviewDecision: "REVIEW_REQUIRED",
            checks: [
                CICheck(name: "regression-tests", state: .success, url: "https://x/1"),
                CICheck(name: "gate", state: .success, url: "https://x/2"),
                CICheck(name: "unit-test", state: .success, url: "https://x/3"),
                CICheck(name: "eval", state: .neutral, url: "https://x/4"),
            ],
            comments: [
                PRComment(
                    author: "joeyfeldberg",
                    body: """
                    Looks close. A couple of asks before merge :point_right:

                    - add a test for the empty-cart path
                    - confirm no extra I/O at lookup time

                    The `cart_lookup` name is good.
                    """,
                    createdAt: "2026-07-15T14:00:00Z",
                    url: "https://x/c1"
                ),
                PRComment(
                    author: "github-actions[bot]",
                    body: """
                    ## Coverage Report :bar_chart:
                    Coverage summary from unit tests run on commit 3ce8a29

                    | Category | Percentage |
                    |-----------|------------|
                    | Total Coverage | 80% |
                    | Files | 92% |
                    """,
                    createdAt: "2026-07-15T13:00:00Z",
                    url: "https://x/c2"
                ),
            ],
            reviews: [
                PRReview(
                    author: "copilot-pull-request-reviewer",
                    state: "COMMENTED",
                    body: """
                    ## Pull request overview

                    Enables the Librarian (context sub-agent) to answer "what's in my cart?" using the
                    customer's actual cart data by fetching the cart during customer load and exposing it
                    via a new `cart_lookup` (no additional I/O at lookup time).
                    """,
                    submittedAt: "2026-07-15T12:00:00Z",
                    url: "https://x/r1"
                ),
            ],
            reviewComments: [
                PRReviewComment(
                    author: "copilot-pull-request-reviewer",
                    body: "This early-return can mask a nil `cart`; consider logging when the lookup misses.",
                    path: "Sources/Agent/CartLookup.swift",
                    line: 42,
                    createdAt: "2026-07-15T12:05:00Z",
                    url: "https://x/rc1"
                ),
                PRReviewComment(
                    author: "copilot-pull-request-reviewer",
                    body: "Nit: `fetchCart` is called twice on the load path — memoize?",
                    path: "Sources/Agent/CustomerLoad.swift",
                    line: 88,
                    createdAt: "2026-07-15T12:06:00Z",
                    url: "https://x/rc2"
                ),
            ]
        )
    }
}

/// Renders coarse `MarkdownBlock`s (from `PRCommentMarkdown`) with SwiftUI. Inline styling
/// (bold/italic/`code`/links) comes from `AttributedString(markdown:)`; block structure from the parser.
struct MarkdownBlockView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level <= 2 ? 12.5 : 11.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        case .paragraph(let text):
            inline(text).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let depth, let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(Theme.textTertiary)
                inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
            .padding(.leading, CGFloat(depth) * 12)
        case .quote(let text):
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.hairlineStrong).frame(width: 2)
                inline(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .padding(7)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .table(let rows):
            Label("Table (\(rows) row\(rows == 1 ? "" : "s")) — open on GitHub", systemImage: "tablecells")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}
