import Foundation
import BalaganCore

// Deterministic smoke-test / UI-driver harness: scenario replay and artifact recording.
// Isolated from the production app file. These run only under explicit launch flags.
// Note: the TerminalSurfaceSession / PlainTextTerminalEmulator core layer is the headless
// backend used *here only* — the live app terminal is libghostty, not this path.
enum ResumeRequestRecorder {
    static func record(plan: ResumeCommandPlan, artifactDirectory: URL?) {
        guard let artifactDirectory else {
            return
        }

        let request = ResumeRequestArtifact(
            surfaceID: plan.surfaceID,
            kind: plan.kind.rawValue,
            displayCommand: plan.displayCommand,
            argv: plan.argv,
            agentName: plan.agentName,
            sessionID: plan.sessionID,
            trust: plan.trust.rawValue,
            requiresConfirmation: plan.requiresConfirmation,
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )

        ArtifactWriter.writeJSON(
            request,
            to: artifactDirectory,
            as: "resume-request.json",
            errorLog: "resume-request-error.log",
            failureMessage: "Failed to record resume request"
        )
    }
}

struct ResumeRequestArtifact: Codable {
    let surfaceID: String
    let kind: String
    let displayCommand: String
    let argv: [String]?
    let agentName: String?
    let sessionID: String?
    let trust: String
    let requiresConfirmation: Bool
    let recordedAt: String
}
