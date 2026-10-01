import Foundation
import BalaganCore

/// Where a surface's readable conversation comes from: the agent's on-disk transcript.
struct ReaderTranscriptSource: Equatable {
    var path: String
    var format: AgentTranscriptFormat
}

/// Reader-mode state + transcript resolution. Extracted from `BoardViewModel`.
extension BoardViewModel {
    func toggleReaderMode() {
        guard selectedTask != nil else { return }
        showingReaderMode.toggle()
        if showingReaderMode { showingChangesView = false }
    }

    /// The surface reader mode / speak-last-response target: the selected task's active surface.
    var selectedTaskActiveSurface: Surface? {
        selectedTask.flatMap(activeSurface(of:))
    }

    func activeSurface(of task: TaskItem) -> Surface? {
        if let selectedID = task.workspace.selectedSurfaceID,
           let surface = task.workspace.surfaces.first(where: { $0.id == selectedID }) {
            return surface
        }
        return task.workspace.surfaces.first
    }

    /// The transcript behind a surface, if the surface belongs to an agent session. Prefers the
    /// captured path; falls back to a session-id search for bindings recorded before capture existed.
    func readerTranscriptSource(for surface: Surface) -> ReaderTranscriptSource? {
        guard let binding = surface.resumeBinding, binding.kind == .agent else { return nil }
        guard let path = TranscriptLocator.default().resolve(
            agentName: binding.agentName,
            sessionID: binding.sessionID,
            storedPath: binding.transcriptPath
        ) else {
            return nil
        }
        return ReaderTranscriptSource(
            path: path,
            format: .infer(agentName: binding.agentName, transcriptPath: path)
        )
    }

    var readerFontSize: Double {
        uiAppearance.effectiveReaderFontSize
    }

    func adjustReaderFontSize(by delta: Double) {
        uiAppearance.readerFontSize = UIAppearanceSettings.clampedReaderFontSize(
            uiAppearance.effectiveReaderFontSize + delta
        )
    }

    var readerTheme: ReaderTheme {
        uiAppearance.effectiveReaderTheme
    }

    func setReaderTheme(_ theme: ReaderTheme) {
        uiAppearance.readerTheme = theme
    }
}
