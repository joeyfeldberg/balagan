import AppKit
import BalaganCore

/// Wires `BoardAutosaver` (Core) to the app: snapshots come from the view model, terminal text
/// from the host registry, and writes go to the launch-configured stores. Capture never mutates
/// the view model — text is overlaid onto the snapshot value inside the autosaver — so saving can
/// no longer re-fire `objectWillChange` and feed itself.
extension BalaganApplication {
    @MainActor
    func makeAutosaver(options: LaunchOptions, viewModel: BoardViewModel) -> BoardAutosaver {
        let databasePath = options.databasePath
        let statePath = options.statePath
        let artifactDirectory = options.artifactDirectory

        return BoardAutosaver(
            makeSnapshot: {
                viewModel.makeSnapshot(savedAt: Date())
            },
            captureTerminalText: { freshness in
                MainActor.assumeIsolated {
                    TerminalHostRegistry.shared.visibleTextSnapshots(fresh: freshness == .fresh).map {
                        TerminalTextCapture(taskID: $0.taskID, surfaceID: $0.surfaceID, text: $0.text)
                    }
                }
            },
            write: { snapshot in
                if let databasePath {
                    try SQLiteBoardStateStore(url: databasePath).save(snapshot)
                }
                if let statePath {
                    try BoardStateFileStore(url: statePath).save(snapshot)
                }
            },
            onError: { error in
                guard let artifactDirectory else {
                    return
                }
                let message = "Failed to persist board state snapshot: \(error)\n"
                try? message.write(
                    to: artifactDirectory.appendingPathComponent("state-error.log"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
    }

    /// Terminal output alone never fires `objectWillChange` anymore, so a crash between model
    /// changes would lose scrollback without this floor: every 30 s, save iff the visible terminal
    /// text differs from the last write.
    @MainActor
    func startPeriodicScrollbackSaves() {
        periodicSaveTimer?.invalidate()
        periodicSaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autosaver?.noteTerminalTextMayHaveChanged()
            }
        }
    }
}
