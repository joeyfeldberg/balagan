import AppKit
import SwiftUI
import BalaganCore

extension BalaganApplication {
    @MainActor
    func writeReadyArtifact(options: LaunchOptions, viewModel: BoardViewModel, window: NSWindow) {
        guard let artifactDirectory = options.artifactDirectory else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            writeWindowSnapshot(window: window, artifactDirectory: artifactDirectory)

            let payload: [String: Any] = [
                "fixture": options.fixtureName,
                "uiTestMode": options.uiTestMode,
                "disableRealProcesses": options.disableRealProcesses,
                "runUIFlowSmoke": options.runUIFlowSmoke,
                "captureTerminalState": options.captureTerminalState,
                "dataSource": viewModel.dataSource,
                "projects": viewModel.projects.count,
                "tasks": viewModel.tasks.count,
                "selectedProjectId": viewModel.selectedProjectID.map { $0 as Any } ?? NSNull(),
                "selectedTaskId": viewModel.selectedTaskID.map { $0 as Any } ?? NSNull(),
                "selectedWorkspaceId": viewModel.selectedWorkspaceID.map { $0 as Any } ?? NSNull(),
                "selectedSurfaceId": viewModel.selectedSurfaceID.map { $0 as Any } ?? NSNull(),
                "terminalAppearance": [
                    "fontSize": viewModel.terminalAppearance.fontSize,
                ],
                "uiAppearance": [
                    "uiScale": viewModel.uiAppearance.uiScale,
                ],
                "storage": storagePayload(options: options),
                "terminalBackend": terminalBackendPayload(options: options),
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: artifactDirectory.appendingPathComponent("app-ready.json"), options: .atomic)

            let tree = viewModel.debugAccessibilityTree()
            try tree.write(
                to: artifactDirectory.appendingPathComponent("accessibility-tree.txt"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            let message = "Failed to write app-ready artifact: \(error)\n"
            try? message.write(
                to: artifactDirectory.appendingPathComponent("app-error.log"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func terminalBackendPayload(options: LaunchOptions) -> [String: Any] {
        let selection = TerminalBackendSelector.select(
            uiTestMode: options.uiTestMode,
            disableRealProcesses: options.disableRealProcesses,
            explicitLibGhosttyPath: options.libGhosttyPath
        )

        return [
            "kind": selection.kind.rawValue,
            "reason": selection.reason,
            "libGhostty": [
                "available": selection.libGhostty.isAvailable,
                "source": selection.libGhostty.source.rawValue,
                "path": selection.libGhostty.path.map { $0 as Any } ?? NSNull(),
                "checkedPaths": selection.libGhostty.checkedPaths,
                "resolvedSymbols": selection.libGhostty.resolvedSymbols,
                "missingSymbols": selection.libGhostty.missingSymbols,
                "diagnostic": selection.libGhostty.diagnostic.map { $0 as Any } ?? NSNull(),
            ],
        ]
    }

    private func storagePayload(options: LaunchOptions) -> [String: Any] {
        [
            "databasePath": options.databasePath.map { $0.path as Any } ?? NSNull(),
            "statePath": options.statePath.map { $0.path as Any } ?? NSNull(),
            "usesDefaultDatabase": options.usesDefaultDatabase,
            "sessionReportSocketPath": options.sessionReportSocketPath,
        ]
    }

    /// Synchronous save used by launch, smoke hooks, and explicit persists (control commands,
    /// session-capture events). High-frequency autosave goes through `autosaver.noteModelChanged()`
    /// instead; both paths overlay live terminal text onto the snapshot value without mutating the
    /// view model (see `BoardAutosaver`).
    @MainActor
    func persistBoardState() {
        autosaver?.saveNow()
    }

    func recordSelectedResumeIfRequested(options: LaunchOptions, viewModel: BoardViewModel) {
        guard options.recordSelectedResume else {
            return
        }

        guard let plan = viewModel.selectedResumePlan else {
            return
        }

        ResumeRequestRecorder.record(plan: plan, artifactDirectory: options.artifactDirectory)
    }

    /// The shared launch-flag smoke hook: when `enabled`, run the recorder's `capture`, then persist +
    /// write the ready artifact; otherwise just record the observed state. The three smoke recorders
    /// differ only in the flag, the observe closure, and the capture closure.
    @MainActor
    private func runSmokeHookIfRequested(
        enabled: Bool,
        options: LaunchOptions,
        viewModel: BoardViewModel,
        recordObservedState: @MainActor (BoardViewModel, URL?) -> Void,
        capture: @MainActor (BoardViewModel) -> Void
    ) {
        guard enabled else {
            recordObservedState(viewModel, options.artifactDirectory)
            return
        }

        capture(viewModel)
        persistBoardState()
        writeReadyArtifactIfPossible(options: options, viewModel: viewModel)
    }

    @MainActor
    func runUIFlowSmokeIfRequested(options: LaunchOptions, viewModel: BoardViewModel) {
        runSmokeHookIfRequested(
            enabled: options.runUIFlowSmoke,
            options: options,
            viewModel: viewModel,
            recordObservedState: UIFlowSmokeRecorder.recordObservedState,
            capture: { UIFlowSmokeRecorder.applyFlow(to: $0, artifactDirectory: options.artifactDirectory) }
        )
    }

    @MainActor
    func runTerminalStateCaptureIfRequested(options: LaunchOptions, viewModel: BoardViewModel) {
        runSmokeHookIfRequested(
            enabled: options.captureTerminalState,
            options: options,
            viewModel: viewModel,
            recordObservedState: TerminalStateCaptureRecorder.recordObservedState,
            capture: {
                TerminalStateCaptureRecorder.capture(
                    viewModel: $0,
                    socketPath: options.sessionReportSocketPath,
                    artifactDirectory: options.artifactDirectory
                )
            }
        )
    }

    @MainActor
    func runAgentReopenCaptureSmokeIfRequested(options: LaunchOptions, viewModel: BoardViewModel) {
        runSmokeHookIfRequested(
            enabled: options.runAgentReopenCaptureSmoke,
            options: options,
            viewModel: viewModel,
            recordObservedState: AgentReopenCaptureSmokeRecorder.recordObservedState,
            capture: {
                AgentReopenCaptureSmokeRecorder.capture(
                    viewModel: $0,
                    socketPath: options.sessionReportSocketPath,
                    artifactDirectory: options.artifactDirectory
                )
            }
        )
    }

    @MainActor
    func writeReadyArtifactIfPossible(options: LaunchOptions, viewModel: BoardViewModel) {
        guard let window else {
            return
        }

        writeReadyArtifact(options: options, viewModel: viewModel, window: window)
    }

    /// Renders a `.sheet` offscreen to `board-sheet.png` for the headless screenshot harness (a real
    /// sheet is captured via `attachedSheet`). Chooses the sheet from a launch env hook.
    @MainActor
    private func writeSheetSnapshotIfRequested(directory: URL) {
        guard let viewModel else { return }
        let env = ProcessInfo.processInfo.environment
        let sheet: AnyView?
        if env["BALAGAN_SHOW_SETTINGS"] == "1" {
            sheet = AnyView(SettingsSheet(viewModel: viewModel))
        } else if env["BALAGAN_SHOW_TASK_FORM"] == "1" {
            var draft = TaskFormDraft.create(projectID: viewModel.projects.first?.id)
            draft.title = "Fix login redirect"
            sheet = AnyView(TaskFormSheet(draft: draft, projects: viewModel.projects, onSave: { _ in }))
        } else if env["BALAGAN_SHOW_PR_POPOVER"] == "1" {
            sheet = AnyView(PullRequestPopover(pullRequest: .snapshotSample, isRefreshing: false, onRefresh: {}))
        } else {
            sheet = nil
        }
        guard let sheet else { return }
        let scale = viewModel.uiAppearance.uiScale
        let hosting = NSHostingView(rootView: sheet.balaganUIScale(scale))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        guard bounds.width > 1, bounds.height > 1,
              let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("board-sheet.png"), options: .atomic)
        }
    }

    @MainActor
    private func writeWindowSnapshot(window: NSWindow, artifactDirectory: URL) {
        let screenshotsDirectory = artifactDirectory.appendingPathComponent("screenshots")

        do {
            try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)

            guard let contentView = window.contentView else {
                throw SnapshotError.missingContentView
            }
            try writePNG(of: contentView, to: screenshotsDirectory.appendingPathComponent("board-app.png"))

            // A `.sheet` (Settings, project/task forms) presents as a separate attached window, so it
            // isn't in the main contentView above — capture it separately when present.
            if let sheet = window.attachedSheet, let sheetView = sheet.contentView {
                try writePNG(of: sheetView, to: screenshotsDirectory.appendingPathComponent("board-sheet.png"))
            } else {
                // Headless (no shown window) never attaches a sheet, so render a requested sheet
                // offscreen — lets the screenshot harness verify it.
                writeSheetSnapshotIfRequested(directory: screenshotsDirectory)
            }
        } catch {
            let message = "app-native screenshot failed: \(error)\n"
            try? message.write(
                to: screenshotsDirectory.appendingPathComponent("board-app.unavailable.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    @MainActor
    private func writePNG(of view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.bitmapCreationFailed
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngCreationFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

private enum SnapshotError: Error {
    case missingContentView
    case bitmapCreationFailed
    case pngCreationFailed
}
