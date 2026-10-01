import XCTest
@testable import BalaganCore

/// Thread-safe recorder handed to `BoardAutosaver` as its writer; can block one write to simulate
/// a slow in-flight save.
private final class SaveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [BoardSnapshot] = []
    private var expectations: [XCTestExpectation] = []
    private var blockNextWrite: DispatchSemaphore?
    private var writeEntered: XCTestExpectation?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count
    }

    var last: BoardSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last
    }

    func expectWrite(_ description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        lock.lock()
        expectations.append(expectation)
        lock.unlock()
        return expectation
    }

    func blockNextWrite(entered: XCTestExpectation) -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        blockNextWrite = semaphore
        writeEntered = entered
        lock.unlock()
        return semaphore
    }

    func write(_ snapshot: BoardSnapshot) {
        lock.lock()
        let semaphore = blockNextWrite
        let entered = writeEntered
        blockNextWrite = nil
        writeEntered = nil
        lock.unlock()

        entered?.fulfill()
        semaphore?.wait()

        lock.lock()
        snapshots.append(snapshot)
        let pending = expectations
        expectations = []
        lock.unlock()
        pending.forEach { $0.fulfill() }
    }
}

final class BoardAutosaverTests: XCTestCase {
    private let debounce: TimeInterval = 0.1

    private func makeSnapshot() -> BoardSnapshot {
        BoardSnapshot(savedAt: BalaganFixtures.baseDate, boardState: BalaganFixtures.boardState())
    }

    private func makeAutosaver(
        probe: SaveProbe,
        captures: @escaping (TerminalCaptureFreshness) -> [TerminalTextCapture] = { _ in [] }
    ) -> BoardAutosaver {
        BoardAutosaver(
            debounceInterval: debounce,
            makeSnapshot: { self.makeSnapshot() },
            captureTerminalText: captures,
            write: { probe.write($0) }
        )
    }

    private func waitForQuiet(windows: Double = 3) {
        let quiet = XCTestExpectation(description: "quiet period")
        quiet.isInverted = true
        wait(for: [quiet], timeout: debounce * windows)
    }

    // MARK: Overlay

    func testOverlayWritesTextIntoWorkspacesAndTasksWithoutTouchingTimestamps() {
        let snapshot = makeSnapshot()
        let capture = TerminalTextCapture(
            taskID: "build-board",
            surfaceID: "surface-terminal",
            text: "$ swift build\nBuild complete!"
        )

        let overlaid = snapshot.overlayingTerminalText([capture])

        let workspace = overlaid.boardState.workspaces.first { $0.taskID == "build-board" }
        XCTAssertEqual(workspace?.surfaces.first?.scrollbackSnapshot, "$ swift build\nBuild complete!")
        let task = overlaid.boardState.tasks.first { $0.id == "build-board" }
        XCTAssertEqual(task?.workspace.surfaces.first?.scrollbackSnapshot, "$ swift build\nBuild complete!")

        // Terminal output is not a user edit: timestamps and every other surface stay untouched.
        XCTAssertEqual(task?.updatedAt, snapshot.boardState.tasks.first { $0.id == "build-board" }?.updatedAt)
        XCTAssertEqual(workspace?.lastOpenedAt, BalaganFixtures.laterDate)
        let untouched = overlaid.boardState.tasks.first { $0.id == "resume-codex" }
        XCTAssertEqual(untouched, snapshot.boardState.tasks.first { $0.id == "resume-codex" })
    }

    func testOverlayWithNoCapturesReturnsIdenticalSnapshot() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.overlayingTerminalText([]), snapshot)
    }

    func testOverlayIgnoresCapturesForUnknownSurfaces() {
        let snapshot = makeSnapshot()
        let capture = TerminalTextCapture(taskID: "no-such-task", surfaceID: "nope", text: "hi")
        XCTAssertEqual(snapshot.overlayingTerminalText([capture]), snapshot)
    }

    // MARK: Coalescing

    func testRapidChangesCoalesceIntoOneWrite() {
        let probe = SaveProbe()
        let autosaver = makeAutosaver(probe: probe)
        let firstWrite = probe.expectWrite("first write")

        for _ in 0..<1000 {
            autosaver.noteModelChanged()
        }

        wait(for: [firstWrite], timeout: 5)
        waitForQuiet()
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(autosaver.completedSaveCount, 1)
    }

    /// The regression test for the 48 GB feedback loop: terminal text that changes on every read
    /// must not, by itself, cause a second save — capture happens on the snapshot value, never
    /// through the model.
    func testChangingTerminalTextDoesNotRetriggerSaves() {
        let probe = SaveProbe()
        let counter = Counter()
        let autosaver = makeAutosaver(probe: probe) { _ in
            [TerminalTextCapture(
                taskID: "build-board",
                surfaceID: "surface-terminal",
                text: "output line \(counter.next())"
            )]
        }
        let firstWrite = probe.expectWrite("first write")

        autosaver.noteModelChanged()

        wait(for: [firstWrite], timeout: 5)
        waitForQuiet(windows: 4)
        XCTAssertEqual(probe.count, 1)
        XCTAssertNotNil(probe.last)
        let saved = probe.last?.boardState.workspaces
            .first { $0.taskID == "build-board" }?
            .surfaces.first?.scrollbackSnapshot
        XCTAssertEqual(saved?.hasPrefix("output line "), true)
    }

    func testChangeArrivingDuringWriteSchedulesExactlyOneFollowUp() {
        let probe = SaveProbe()
        let autosaver = makeAutosaver(probe: probe)
        let entered = XCTestExpectation(description: "write entered")
        let semaphore = probe.blockNextWrite(entered: entered)

        autosaver.noteModelChanged()
        wait(for: [entered], timeout: 5)

        let secondWrite = probe.expectWrite("follow-up write")
        for _ in 0..<5 {
            autosaver.noteModelChanged()
        }
        semaphore.signal()

        wait(for: [secondWrite], timeout: 5)
        waitForQuiet()
        XCTAssertEqual(probe.count, 2)
    }

    // MARK: Synchronous saves

    func testSaveNowWritesSynchronouslyAndCancelsPendingDebounce() {
        let probe = SaveProbe()
        let autosaver = makeAutosaver(probe: probe)

        autosaver.noteModelChanged()
        autosaver.saveNow()

        XCTAssertEqual(probe.count, 1)
        waitForQuiet()
        XCTAssertEqual(probe.count, 1)
    }

    func testFlushForTerminationWritesOnceAndStopsFutureSaves() {
        let probe = SaveProbe()
        let autosaver = makeAutosaver(probe: probe)

        autosaver.flushForTermination()
        XCTAssertEqual(probe.count, 1)

        autosaver.noteModelChanged()
        autosaver.saveNow()
        waitForQuiet()
        XCTAssertEqual(probe.count, 1)
    }

    // MARK: Periodic text floor

    func testPeriodicTextCheckSavesOnlyWhenTextChanged() {
        let probe = SaveProbe()
        let text = TextBox(value: "stable output")
        let autosaver = makeAutosaver(probe: probe) { _ in
            [TerminalTextCapture(taskID: "build-board", surfaceID: "surface-terminal", text: text.value)]
        }

        autosaver.saveNow()
        XCTAssertEqual(probe.count, 1)

        autosaver.noteTerminalTextMayHaveChanged()
        waitForQuiet()
        XCTAssertEqual(probe.count, 1, "unchanged text must not trigger a save")

        text.value = "new output"
        let secondWrite = probe.expectWrite("save after text change")
        autosaver.noteTerminalTextMayHaveChanged()
        wait(for: [secondWrite], timeout: 5)
        XCTAssertEqual(probe.count, 2)
    }

    /// Fresh terminal reads leak ~3 KB inside libghostty per call, so which saves read live and
    /// which reuse the cache is load-bearing: only synchronous saves and the periodic floor may
    /// read fresh; debounced background saves must serve the cache.
    func testDebouncedSavesUseCachedCapturesAndSyncPathsReadFresh() {
        let probe = SaveProbe()
        let seen = FreshnessLog()
        let autosaver = makeAutosaver(probe: probe) { freshness in
            seen.append(freshness)
            return []
        }

        autosaver.saveNow()
        XCTAssertEqual(seen.values, [.fresh])

        let backgroundWrite = probe.expectWrite("debounced write")
        autosaver.noteModelChanged()
        wait(for: [backgroundWrite], timeout: 5)
        XCTAssertEqual(seen.values, [.fresh, .cached])

        // Let the write-completion hop back to the main queue and clear the in-flight flag,
        // otherwise the periodic check below early-returns without capturing.
        waitForQuiet(windows: 1)
        autosaver.noteTerminalTextMayHaveChanged()
        XCTAssertEqual(seen.values.last, .fresh, "the periodic floor must read live text to detect changes")
    }

    // MARK: End-to-end with the real SQLite store

    func testStormWithChangingTextWritesBoundedSavesAndFinalStateToSQLite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosaver-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("board.sqlite3")
        let store = SQLiteBoardStateStore(url: databaseURL)

        let counter = Counter()
        let writeCount = Counter()
        let autosaver = BoardAutosaver(
            debounceInterval: debounce,
            makeSnapshot: { self.makeSnapshot() },
            captureTerminalText: { _ in
                [TerminalTextCapture(
                    taskID: "build-board",
                    surfaceID: "surface-terminal",
                    text: "storm line \(counter.next())"
                )]
            },
            write: {
                try store.save($0)
                writeCount.next()
            }
        )

        // Three bursts of rapid changes, each inside its own debounce window.
        for burst in 1...3 {
            for _ in 0..<200 {
                autosaver.noteModelChanged()
            }
            let expectation = XCTestExpectation(description: "burst \(burst) settled")
            expectation.isInverted = true
            wait(for: [expectation], timeout: debounce * 3)
        }
        autosaver.flushForTermination()

        XCTAssertLessThanOrEqual(writeCount.value, 5, "600 changes must coalesce into a handful of writes")
        let loaded = try store.load()
        let saved = loaded.boardState.workspaces
            .first { $0.taskID == "build-board" }?
            .surfaces.first?.scrollbackSnapshot
        XCTAssertEqual(saved?.hasPrefix("storm line "), true, "the final write must carry the latest terminal text")
    }
}

/// Tiny thread-safe counter/box helpers for provider closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class FreshnessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TerminalCaptureFreshness] = []

    func append(_ value: TerminalCaptureFreshness) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(value)
    }

    var values: [TerminalCaptureFreshness] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(value: String) {
        stored = value
    }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
