import Foundation
import SQLite3

public struct CodexSessionThread: Equatable, Sendable {
    public var id: String
    public var rolloutPath: String?
    public var createdAtMs: Int64
    public var cwd: String

    public init(id: String, rolloutPath: String?, createdAtMs: Int64, cwd: String) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.createdAtMs = createdAtMs
        self.cwd = cwd
    }
}

public enum CodexSessionCaptureResult: Equatable, Sendable {
    case captured(String)
    case notFound
    case ambiguous([String])

    public var sessionID: String? {
        if case let .captured(sessionID) = self {
            return sessionID
        }
        return nil
    }
}

public enum CodexResumeRecoveryResult: Equatable, Sendable {
    case notNeeded
    case recovered(Surface)
    case missing
    case ambiguous([String])
}

public enum CodexResumeRecovery {
    private static let legacyFallbackWindowMs: Int64 = 14 * 24 * 60 * 60 * 1_000

    public static func recover(
        surface: Surface,
        taskID: Task.ID,
        workspaceID: Workspace.ID? = nil,
        capture: CodexSessionCapture,
        environment: [String: String] = [:],
        legacyReferenceDate: Date? = nil,
        recoveredAt: Date = .now
    ) throws -> CodexResumeRecoveryResult {
        if surface.resumeBinding != nil {
            return .notNeeded
        }

        guard let recoveryRequest = recoveryRequest(
            for: surface,
            legacyReferenceDate: legacyReferenceDate,
            recoveredAt: recoveredAt
        ) else {
            return .notNeeded
        }

        switch try capture.capture(cwd: recoveryRequest.cwd, startMs: recoveryRequest.startMs) {
        case .captured(let sessionID):
            var recoveredSurface = surface
            recoveredSurface.resumeBinding = ResumeBinding(
                id: "resume-\(surface.id)",
                taskID: taskID,
                workspaceID: workspaceID ?? surface.workspaceID,
                surfaceID: surface.id,
                kind: .agent,
                agentName: "codex",
                sessionID: sessionID,
                command: "codex resume \(sessionID)",
                trust: .trusted,
                source: .agentHook,
                argv: ["codex"],
                cwd: recoveryRequest.cwd,
                capturedAt: recoveredAt,
                captureUpdatedAt: recoveredAt,
                wasRunning: true,
                isRestorable: true,
                isStale: false,
                autoResume: true,
                sanitizedEnvironment: EnvironmentSanitizer().sanitize(environment),
                createdAt: recoveredAt,
                updatedAt: recoveredAt
            )
            return .recovered(recoveredSurface)
        case .notFound:
            return .missing
        case .ambiguous(let sessionIDs):
            return .ambiguous(sessionIDs)
        }
    }

    private struct RecoveryRequest {
        var cwd: String
        var startMs: Int64
    }

    private static func recoveryRequest(
        for surface: Surface,
        legacyReferenceDate: Date?,
        recoveredAt: Date
    ) -> RecoveryRequest? {
        guard let startupCommand = surface.startupCommand?.nilIfBlank else {
            return nil
        }

        if let metadata = surface.agentLaunchMetadata,
           metadata.agentName.caseInsensitiveCompare("codex") == .orderedSame,
           CodexCommandHeuristics.isFreshBalaganCodexCommand(metadata.startupCommand) {
            return RecoveryRequest(cwd: metadata.cwd, startMs: metadata.captureStartedAtMs)
        }

        guard CodexCommandHeuristics.isFreshBalaganCodexCommand(startupCommand),
              let snapshot = surface.scrollbackSnapshot?.nilIfBlank,
              CodexCommandHeuristics.snapshotContainsFreshCodexLaunch(snapshot)
        else {
            return nil
        }

        let referenceDate = legacyReferenceDate ?? recoveredAt
        let recoveredAtMs = referenceDate.millisecondsSince1970
        return RecoveryRequest(
            cwd: surface.cwd,
            startMs: max(0, recoveredAtMs - legacyFallbackWindowMs)
        )
    }

}

public struct CodexSessionCapture: Sendable {
    public static let defaultStartSkewAllowanceMs: Int64 = 60_000

    public var stateDatabaseURL: URL
    public var sessionsDirectoryURL: URL
    public var startSkewAllowanceMs: Int64

    public init(
        stateDatabaseURL: URL,
        sessionsDirectoryURL: URL,
        startSkewAllowanceMs: Int64 = CodexSessionCapture.defaultStartSkewAllowanceMs
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.sessionsDirectoryURL = sessionsDirectoryURL
        self.startSkewAllowanceMs = startSkewAllowanceMs
    }

    public static func `default`(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodexSessionCapture {
        CodexSessionCapture(
            stateDatabaseURL: homeDirectory.appendingPathComponent(".codex/state_5.sqlite"),
            sessionsDirectoryURL: homeDirectory.appendingPathComponent(".codex/sessions")
        )
    }

    /// Builds a capture rooted at `BALAGAN_CODEX_CAPTURE_HOME` (when set) or the current user's home
    /// directory otherwise. Folds the resolution repeated across the recovery, smoke, and wrapper paths.
    public static func fromEnvironment(_ environment: [String: String]) -> CodexSessionCapture {
        let captureHome = environment["BALAGAN_CODEX_CAPTURE_HOME"].map(URL.init(fileURLWithPath:))
        return `default`(homeDirectory: captureHome ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    public func capture(cwd: String, startMs: Int64) throws -> CodexSessionCaptureResult {
        let dbResult = try captureFromStateDatabase(cwd: cwd, startMs: startMs)
        switch dbResult {
        case .captured, .ambiguous:
            return dbResult
        case .notFound:
            return try captureFromRolloutFiles(cwd: cwd, startMs: startMs)
        }
    }

    public func captureFromStateDatabase(cwd: String, startMs: Int64) throws -> CodexSessionCaptureResult {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return .notFound
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(stateDatabaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            defer {
                if let database {
                    sqlite3_close(database)
                }
            }
            return .notFound
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT id, rollout_path, created_at_ms, cwd
        FROM threads
        WHERE created_at_ms >= ?
        ORDER BY created_at_ms ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .notFound
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, skewedStartMs(from: startMs))

        var matches: [CodexSessionThread] = []
        let expectedCwd = normalizedPath(cwd)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let cwdPointer = sqlite3_column_text(statement, 3)
            else {
                continue
            }
            let rowCwd = String(cString: cwdPointer)
            guard normalizedPath(rowCwd) == expectedCwd else {
                continue
            }
            let rolloutPath = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            matches.append(CodexSessionThread(
                id: String(cString: idPointer),
                rolloutPath: rolloutPath,
                createdAtMs: sqlite3_column_int64(statement, 2),
                cwd: rowCwd
            ))
        }

        return mostRecentThreadResult(matches, startMs: startMs)
    }

    public func captureFromRolloutFiles(cwd: String, startMs: Int64) throws -> CodexSessionCaptureResult {
        guard FileManager.default.fileExists(atPath: sessionsDirectoryURL.path) else {
            return .notFound
        }

        let urls = FileManager.default.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        var matches: [(id: String, createdAtMs: Int64)] = []
        let expectedCwd = normalizedPath(cwd)
        for url in urls where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modifiedAt = attributes?[.modificationDate] as? Date
            if let modifiedAt, modifiedAt.millisecondsSince1970 < skewedStartMs(from: startMs) {
                continue
            }
            if let rollout = try firstSessionMeta(in: url),
               normalizedPath(rollout.cwd) == expectedCwd {
                let createdAtMs = modifiedAt.map { $0.millisecondsSince1970 } ?? startMs
                if createdAtMs >= startMs || createdAtMs >= skewedStartMs(from: startMs) {
                    matches.append((rollout.id, createdAtMs))
                }
            }
        }

        return mostRecentRolloutResult(matches)
    }

    public func recoverCodexResumeBinding(
        surface: Surface,
        taskID: Task.ID,
        workspaceID: Workspace.ID? = nil,
        environment: [String: String] = [:],
        legacyReferenceDate: Date? = nil,
        recoveredAt: Date = .now
    ) throws -> CodexResumeRecoveryResult {
        try CodexResumeRecovery.recover(
            surface: surface,
            taskID: taskID,
            workspaceID: workspaceID,
            capture: self,
            environment: environment,
            legacyReferenceDate: legacyReferenceDate,
            recoveredAt: recoveredAt
        )
    }

    private struct RolloutSessionMeta {
        var id: String
        var cwd: String
    }

    private func firstSessionMeta(in url: URL) throws -> RolloutSessionMeta? {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var sessionID: String?
        var cwd: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else {
                continue
            }
            if type == "session_meta" {
                if let id = payload["id"] as? String, id.isEmpty == false {
                    sessionID = id
                }
                // Newer rollout layouts carry the cwd on session_meta rather than only turn_context.
                if cwd == nil {
                    cwd = (payload["cwd"] as? String)?.nilIfBlank
                }
            }
            if type == "turn_context" {
                cwd = (payload["cwd"] as? String)?.nilIfBlank
                    ?? ((payload["context"] as? [String: Any])?["cwd"] as? String)?.nilIfBlank
            }
            if let sessionID, let cwd {
                return RolloutSessionMeta(id: sessionID, cwd: cwd)
            }
        }
        return nil
    }

    /// Resolves cwd matches to the session started most recently — the one the surface most likely had
    /// when the app quit. Prefers sessions started inside the launch window, falling back to all matches
    /// when none qualify; `.notFound` only when there are none. (We no longer bail as `.ambiguous` when a
    /// cwd has several historical sessions — resuming the latest beats a dead placeholder.)
    private func mostRecentThreadResult(_ threads: [CodexSessionThread], startMs: Int64) -> CodexSessionCaptureResult {
        let inWindow = threads.filter { $0.createdAtMs >= startMs }
        let candidates = inWindow.isEmpty ? threads : inWindow
        guard let latest = candidates.max(by: { $0.createdAtMs < $1.createdAtMs }) else {
            return .notFound
        }
        return .captured(latest.id)
    }

    private func mostRecentRolloutResult(_ matches: [(id: String, createdAtMs: Int64)]) -> CodexSessionCaptureResult {
        guard let latest = matches.max(by: { $0.createdAtMs < $1.createdAtMs }) else {
            return .notFound
        }
        return .captured(latest.id)
    }

    private func skewedStartMs(from startMs: Int64) -> Int64 {
        max(0, startMs - max(0, startSkewAllowanceMs))
    }

    private func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
