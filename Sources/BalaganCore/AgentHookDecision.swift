/// What one Claude hook invocation does, decided before any I/O: drop it (and the reason the hook log
/// records), or send this report to the app. The wrapper only reads stdin, sends, and logs.
public enum AgentHookDecision: Equatable, Sendable {
    case drop(AgentHookLogOutcome, lifecycle: AgentLifecycle?, toolName: String?)
    case send(SessionReportEvent, lifecycle: AgentLifecycle?, toolName: String?)
}

extension AgentHookEvent {
    public func decision(
        payload: AgentHookPayload,
        balaganEnvironment: AgentWrapperEnvironment?,
        processEnvironment: [String: String],
        currentDirectory: String
    ) -> AgentHookDecision {
        // A subagent's hook (payload carries `agent_id`) is dropped by `report(payload:)` too; checked
        // here first so the log can say *why* it was dropped.
        if self != .sessionStart, payload.agentID != nil {
            return .drop(.droppedSubagent, lifecycle: nil, toolName: payload.toolName)
        }
        guard let report = report(payload: payload) else {
            return .drop(.droppedNoMapping, lifecycle: nil, toolName: payload.toolName)
        }
        guard let balaganEnvironment else {
            return .drop(.droppedMissingEnv, lifecycle: report.lifecycle, toolName: report.toolName)
        }
        // session-start creates/refreshes the resume binding and needs a session id; the working-state
        // events are matched by surface (from env) and don't require one.
        if report.kind == .sessionStart, payload.sessionID == nil {
            return .drop(.droppedNoSessionID, lifecycle: report.lifecycle, toolName: report.toolName)
        }
        let event = SessionReportEvent(
            event: report.kind,
            taskID: balaganEnvironment.taskID,
            workspaceID: balaganEnvironment.workspaceID,
            surfaceID: balaganEnvironment.surfaceID,
            agentName: "claude",
            sessionID: payload.sessionID,
            cwd: payload.cwd ?? currentDirectory,
            transcriptPath: payload.transcriptPath,
            status: "running",
            command: payload.sessionID.map { "claude --resume \($0)" },
            lifecycle: report.lifecycle?.rawValue,
            toolName: report.toolName,
            environment: processEnvironment
        )
        return .send(event, lifecycle: report.lifecycle, toolName: report.toolName)
    }
}
