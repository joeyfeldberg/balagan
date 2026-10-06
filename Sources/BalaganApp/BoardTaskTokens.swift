import BalaganCore
import Foundation
import SwiftUI

/// Tokens and API-equivalent cost per task, summed over its agent tabs' current sessions and read
/// from their transcripts (`TranscriptTokenCounter`, Core). Counting is incremental: each transcript
/// keeps a counter that only reads what was appended since last time.
extension BoardViewModel {
    static let tokenQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.task-tokens", qos: .utility)

    /// Re-counts the given tasks (all of them when nil). Cheap after the first pass.
    func refreshTaskTokens(taskIDs: Set<TaskItem.ID>? = nil) {
        guard tokenTrackingEnabled else { return }
        let jobs: [(TaskItem.ID, [ResumeBinding])] = tasks.compactMap { task in
            if let taskIDs, taskIDs.contains(task.id) == false { return nil }
            let bindings = task.workspace.surfaces.compactMap(\.resumeBinding).filter { $0.kind == .agent }
            return bindings.isEmpty ? nil : (task.id, bindings)
        }
        guard jobs.isEmpty == false else { return }
        Self.tokenQueue.async { [weak self] in
            let locator = TranscriptLocator.default()
            var results: [TaskItem.ID: TokenUsage] = [:]
            for (taskID, bindings) in jobs {
                let usages = bindings.compactMap { binding -> TokenUsage? in
                    guard let path = locator.resolve(agentName: binding.agentName, sessionID: binding.sessionID, storedPath: binding.transcriptPath) else { return nil }
                    let format: TranscriptTokenCounter.Format = AgentTranscriptFormat.infer(agentName: binding.agentName, transcriptPath: path) == .codex ? .codex : .claude
                    return TranscriptTokenCache.shared.usage(path: path, format: format)
                }
                let total = usages.reduce(TokenUsage(), +)
                if total.isEmpty == false { results[taskID] = total }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (taskID, usage) in results where self.taskTokenUsage[taskID] != usage {
                    self.taskTokenUsage[taskID] = usage
                }
            }
        }
    }

    /// `BALAGAN_FIXTURE_TOKENS=1`: sample numbers for a snapshot.
    func seedTaskTokensForSnapshot() {
        let ids = tasks.filter { $0.isProjectTerminals == false }.map(\.id)
        let samples: [TokenUsage] = [
            TokenUsage(inputTokens: 1_200, cacheWriteTokens: 410_000, cacheReadTokens: 6_800_000, outputTokens: 52_000, costUSD: 4.71, models: ["claude-opus-5-5"]),
            TokenUsage(inputTokens: 70_000, cacheReadTokens: 1_050_000, outputTokens: 15_000, models: ["gpt-6.1-sol"]),
        ]
        for (id, usage) in zip(ids, samples) { taskTokenUsage[id] = usage }
    }
}

/// One incremental counter per transcript file, touched only on `BoardViewModel.tokenQueue`.
final class TranscriptTokenCache: @unchecked Sendable {
    static let shared = TranscriptTokenCache()
    private var counters: [String: TranscriptTokenCounter] = [:]

    func usage(path: String, format: TranscriptTokenCounter.Format) -> TokenUsage? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var counter = counters[path] ?? TranscriptTokenCounter(format: format)
        // A file that shrank was replaced: count it again from the start.
        if size < counter.offset { counter = TranscriptTokenCounter(format: format) }
        if size > counter.offset {
            try? handle.seek(toOffset: counter.offset)
            if let data = try? handle.readToEnd() { counter.consume(data) }
        }
        counters[path] = counter
        return counter.usage
    }
}

/// "≈ $4.71 · 7.3M tokens" on a card; hover for the breakdown.
struct TaskTokenBadge: View {
    let usage: TokenUsage
    @Environment(\.balaganUIScale) private var scale

    var body: some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 8.5 * scale))
            Text(verbatim: Self.summary(usage))
        }
        .font(.system(size: Theme.TextSize.micro * scale, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.textTertiary)
        .help(Self.breakdown(usage))
        .accessibilityIdentifier("task-tokens")
    }

    static func summary(_ usage: TokenUsage) -> String {
        let tokens = "\(TokenUsage.compact(usage.totalTokens)) tokens"
        guard let cost = usage.costUSD else { return tokens }
        return "≈ \(currency(cost)) · \(tokens)"
    }

    static func currency(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func breakdown(_ usage: TokenUsage) -> String {
        var lines = [
            "Input: \(TokenUsage.compact(usage.inputTokens))",
            "Cache writes: \(TokenUsage.compact(usage.cacheWriteTokens))",
            "Cache reads: \(TokenUsage.compact(usage.cacheReadTokens))",
            "Output: \(TokenUsage.compact(usage.outputTokens))",
        ]
        if usage.models.isEmpty == false { lines.append("Models: \(usage.models.sorted().joined(separator: ", "))") }
        if let cost = usage.costUSD {
            lines.append("≈ \(currency(cost)) at Anthropic API prices (a subscription isn't billed per token)")
            if usage.models.contains(where: { $0.hasPrefix("claude") == false }) {
                lines.append("Non-Claude models aren't priced")
            }
        } else {
            lines.append("No price for these models; tokens only")
        }
        lines.append("Counts each tab's current session")
        return lines.joined(separator: "\n")
    }
}
