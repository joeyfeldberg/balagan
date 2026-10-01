import Foundation

/// Whether a terminal-text capture may serve cached text or must read the live terminal.
/// Fresh reads are rationed deliberately: `ghostty_surface_read_text` leaks ~3 KB inside
/// libghostty 1.3.1 per call, so only the periodic floor, explicit saves, and the termination
/// flush read live; debounced background saves reuse the cache (at most one floor interval stale).
public enum TerminalCaptureFreshness: Sendable {
    case cached
    case fresh
}

/// One live terminal surface's visible text, captured from the terminal layer at save time.
public struct TerminalTextCapture: Equatable, Sendable {
    public var taskID: TaskItem.ID
    public var surfaceID: Surface.ID
    public var text: String

    public init(taskID: TaskItem.ID, surfaceID: Surface.ID, text: String) {
        self.taskID = taskID
        self.surfaceID = surfaceID
        self.text = text
    }
}

extension BoardSnapshot {
    /// Returns a copy with the captured terminal text written into the matching surfaces'
    /// `scrollbackSnapshot` — in both `boardState.workspaces` (the copy the load path prefers) and
    /// the tasks' embedded workspaces.
    ///
    /// This is how autosave persists terminal text *without mutating the live model*: capturing
    /// into the view model from the save path re-fires `objectWillChange`, which re-queues a save —
    /// the feedback loop that let the app run away to a 48 GB footprint. Overlaying onto the value
    /// snapshot makes that loop impossible. Deliberately leaves `updatedAt`/`lastOpenedAt` alone:
    /// a terminal printing output is not a user edit.
    public func overlayingTerminalText(_ captures: [TerminalTextCapture]) -> BoardSnapshot {
        guard captures.isEmpty == false else {
            return self
        }

        var textByTaskAndSurface: [TaskItem.ID: [Surface.ID: String]] = [:]
        for capture in captures {
            textByTaskAndSurface[capture.taskID, default: [:]][capture.surfaceID] = capture.text
        }

        func overlaid(_ workspace: Workspace, taskID: TaskItem.ID) -> Workspace {
            guard let texts = textByTaskAndSurface[taskID] else {
                return workspace
            }
            var updated = workspace
            updated.surfaces = updated.surfaces.map { surface in
                guard let text = texts[surface.id] else {
                    return surface
                }
                var updatedSurface = surface
                updatedSurface.scrollbackSnapshot = text.isEmpty ? nil : text
                return updatedSurface
            }
            return updated
        }

        var snapshot = self
        snapshot.boardState.workspaces = boardState.workspaces.map { overlaid($0, taskID: $0.taskID) }
        snapshot.boardState.tasks = boardState.tasks.map { task in
            var updated = task
            updated.workspace = overlaid(task.workspace, taskID: task.id)
            return updated
        }
        return snapshot
    }
}

/// Coalesces board-state persistence so bursts of model changes produce bounded work.
///
/// - A model change schedules one save after `debounceInterval`; further changes inside the window
///   are absorbed (the window is fixed, not sliding, so continuous terminal output can't starve it).
/// - At most one write is in flight. A change arriving mid-write sets a dirty flag and schedules
///   exactly one follow-up save when the write completes.
/// - The snapshot value (plus terminal-text overlay) is captured on `callbackQueue`; JSON encoding
///   and store writes happen on a private serial queue, off the main thread.
/// - `saveNow()`/`flushForTermination()` write synchronously; the serial write queue orders them
///   after any in-flight background write.
///
/// Threading contract: all public methods must be called on `callbackQueue` (the main queue in the
/// app). The providers are invoked on `callbackQueue`; `write` is invoked on the private queue.
public final class BoardAutosaver: @unchecked Sendable {
    public typealias SnapshotProvider = () -> BoardSnapshot
    public typealias CaptureProvider = (TerminalCaptureFreshness) -> [TerminalTextCapture]
    public typealias SnapshotWriter = @Sendable (BoardSnapshot) throws -> Void

    private let debounceInterval: TimeInterval
    private let callbackQueue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "balagan.board-autosave-writer", qos: .utility)
    private let makeSnapshot: SnapshotProvider
    private let captureTerminalText: CaptureProvider
    private let write: SnapshotWriter
    private let onError: (@Sendable (Error) -> Void)?

    // All mutable state is confined to `callbackQueue`.
    private var pendingSave: DispatchWorkItem?
    private var isWriting = false
    private var changedDuringWrite = false
    private var isShutDown = false
    private var lastWrittenCaptures: [TerminalTextCapture] = []
    public private(set) var completedSaveCount = 0

    public init(
        debounceInterval: TimeInterval = 1.0,
        callbackQueue: DispatchQueue = .main,
        makeSnapshot: @escaping SnapshotProvider,
        captureTerminalText: @escaping CaptureProvider,
        write: @escaping SnapshotWriter,
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.debounceInterval = debounceInterval
        self.callbackQueue = callbackQueue
        self.makeSnapshot = makeSnapshot
        self.captureTerminalText = captureTerminalText
        self.write = write
        self.onError = onError
    }

    /// Requests a coalesced background save. Safe to call at any frequency.
    public func noteModelChanged() {
        guard isShutDown == false else {
            return
        }
        if isWriting {
            changedDuringWrite = true
            return
        }
        guard pendingSave == nil else {
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.beginBackgroundSave()
        }
        pendingSave = item
        callbackQueue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// The periodic crash-safety floor: terminal output alone never fires `noteModelChanged` (the
    /// save path no longer mutates the model), so a timer calls this to persist scrollback that
    /// changed since the last write. No-ops when the captured text is unchanged.
    public func noteTerminalTextMayHaveChanged() {
        guard isShutDown == false, isWriting == false, pendingSave == nil else {
            return
        }
        // The one routine fresh read: it refreshes the terminal layer's cache, so the debounced
        // saves' cached captures are never older than this floor's interval.
        guard captureTerminalText(.fresh) != lastWrittenCaptures else {
            return
        }
        noteModelChanged()
    }

    /// Synchronous save for launch-time writes, smoke hooks, and rare explicit persists (control
    /// commands, session-capture events). Cancels any pending debounced save (its content is
    /// covered by this write).
    public func saveNow() {
        guard isShutDown == false else {
            return
        }
        performSynchronousSave()
    }

    /// Final save at app termination; further save requests are ignored afterwards so nothing
    /// writes during teardown.
    public func flushForTermination() {
        guard isShutDown == false else {
            return
        }
        isShutDown = true
        performSynchronousSave()
    }

    private func performSynchronousSave() {
        pendingSave?.cancel()
        pendingSave = nil

        let captures = captureTerminalText(.fresh)
        let snapshot = makeSnapshot().overlayingTerminalText(captures)

        var failure: Error?
        writeQueue.sync {
            do {
                try self.write(snapshot)
            } catch {
                failure = error
            }
        }
        finishSave(captures: captures, error: failure)
    }

    private func beginBackgroundSave() {
        pendingSave = nil
        guard isShutDown == false else {
            return
        }

        let captures = captureTerminalText(.cached)
        let snapshot = makeSnapshot().overlayingTerminalText(captures)
        isWriting = true
        writeQueue.async { [weak self] in
            guard let self else {
                return
            }
            var thrown: Error?
            do {
                try self.write(snapshot)
            } catch {
                thrown = error
            }
            let failure = thrown
            self.callbackQueue.async {
                self.isWriting = false
                self.finishSave(captures: captures, error: failure)
                if self.changedDuringWrite {
                    self.changedDuringWrite = false
                    self.noteModelChanged()
                }
            }
        }
    }

    private func finishSave(captures: [TerminalTextCapture], error: Error?) {
        if let error {
            // Leaving `lastWrittenCaptures` stale on purpose: the periodic text check will retry.
            onError?(error)
        } else {
            lastWrittenCaptures = captures
            completedSaveCount += 1
        }
    }
}
