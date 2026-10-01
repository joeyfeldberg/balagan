import XCTest
@testable import BalaganCore

final class BoardStateStoreTests: XCTestCase {
    func testSnapshotRoundTripsThroughFileStore() throws {
        let directory = temporaryDirectory()
        let store = BoardStateFileStore(url: directory.appendingPathComponent("Balagan.state.json"))
        let snapshot = BoardSnapshot(
            savedAt: BalaganFixtures.laterDate,
            boardState: BalaganFixtures.boardState(),
            uiState: PersistedUIState(
                selectedProjectID: "balagan",
                selectedTaskID: "resume-codex",
                selectedWorkspaceID: "workspace-build-board",
                selectedSurfaceID: "surface-terminal",
                terminalAppearance: TerminalAppearanceSettings(fontSize: 16),
                uiAppearance: UIAppearanceSettings(uiScale: 1.2, sidebarScale: 1.05)
            )
        )

        try store.save(snapshot)
        let loaded = try store.load()

        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.uiState.uiAppearance.sidebarScale, 1.05)
    }

    func testSnapshotRoundTripsThroughSQLiteStore() throws {
        let directory = temporaryDirectory()
        let store = SQLiteBoardStateStore(url: directory.appendingPathComponent("Balagan.sqlite"))
        let snapshot = BoardSnapshot(
            savedAt: BalaganFixtures.laterDate,
            boardState: BalaganFixtures.boardState(),
            uiState: PersistedUIState(
                selectedProjectID: "balagan",
                selectedTaskID: "resume-codex",
                selectedWorkspaceID: "workspace-build-board",
                selectedSurfaceID: "surface-terminal",
                terminalAppearance: TerminalAppearanceSettings(fontSize: 15),
                uiAppearance: UIAppearanceSettings(uiScale: 0.9)
            )
        )

        try store.save(snapshot)
        let loaded = try store.load()

        XCTAssertEqual(loaded, snapshot)
    }

    func testProjectDefaultAgentCommandPersistsThroughJSONAndSQLite() throws {
        let project = BalaganFixtures.project(defaultAgentCommand: AgentCommandDefaults.claude)
        let snapshot = BoardSnapshot(
            savedAt: BalaganFixtures.laterDate,
            boardState: BoardState(projects: [project])
        )

        let jsonData = try BoardSnapshot.jsonEncoder().encode(snapshot)
        let jsonLoaded = try BoardSnapshot.jsonDecoder().decode(BoardSnapshot.self, from: jsonData)

        XCTAssertEqual(jsonLoaded.boardState.projects.first?.defaultAgentCommand, AgentCommandDefaults.claude)

        let sqliteStore = SQLiteBoardStateStore(url: temporaryDirectory().appendingPathComponent("Balagan.sqlite"))
        try sqliteStore.save(snapshot)
        let sqliteLoaded = try sqliteStore.load()

        XCTAssertEqual(sqliteLoaded.boardState.projects.first?.defaultAgentCommand, AgentCommandDefaults.claude)
    }

    func testSQLiteStoreReturnsNilWhenNoSnapshotExists() throws {
        let store = SQLiteBoardStateStore(url: temporaryDirectory().appendingPathComponent("Balagan.sqlite"))

        let loaded = try store.loadLatest()

        XCTAssertNil(loaded)
    }

    func testPersistedUIStateDefaultsAppearanceForLegacySnapshots() throws {
        let data = """
        {
          "selectedProjectID": "balagan",
          "selectedTaskID": "resume-codex",
          "selectedWorkspaceID": "workspace-build-board",
          "selectedSurfaceID": "surface-terminal"
        }
        """.data(using: .utf8)!

        let uiState = try BoardSnapshot.jsonDecoder().decode(PersistedUIState.self, from: data)

        XCTAssertEqual(uiState.terminalAppearance, TerminalAppearanceSettings())
        XCTAssertEqual(uiState.uiAppearance, UIAppearanceSettings())
    }

    func testUIAppearanceClampsScale() {
        XCTAssertEqual(UIAppearanceSettings(uiScale: 0.2).uiScale, UIAppearanceSettings.minimumScale)
        XCTAssertEqual(UIAppearanceSettings(uiScale: 2).uiScale, UIAppearanceSettings.maximumScale)
    }

    func testSidebarScaleFallsBackToUIScaleWhenUnset() {
        let unified = UIAppearanceSettings(uiScale: 1.2)
        XCTAssertNil(unified.sidebarScale)
        XCTAssertEqual(unified.effectiveSidebarScale, 1.2, accuracy: 0.0001)
    }

    func testSidebarScaleIsIndependentAndClamped() {
        let split = UIAppearanceSettings(uiScale: 1.0, sidebarScale: 1.3)
        XCTAssertEqual(split.effectiveSidebarScale, 1.3, accuracy: 0.0001)
        XCTAssertEqual(split.uiScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(UIAppearanceSettings(uiScale: 1.0, sidebarScale: 5).effectiveSidebarScale, UIAppearanceSettings.maximumScale)
        XCTAssertEqual(UIAppearanceSettings(uiScale: 1.0, sidebarScale: 0.1).effectiveSidebarScale, UIAppearanceSettings.minimumScale)
    }

    func testSplitLayoutAndResumeSurfacesRoundTripThroughJSONAndSQLite() throws {
        let primaryBinding = BalaganFixtures.resumeBinding(
            id: "resume-codex",
            surfaceID: "surface-codex",
            kind: .agent,
            agentName: "codex",
            sessionID: "codex-session-123",
            command: "codex resume codex-session-123",
            trust: .trusted,
            sanitizedEnvironment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        )
        let secondaryBinding = BalaganFixtures.resumeBinding(
            id: "resume-tmux",
            surfaceID: "surface-shell",
            kind: .tmux,
            sessionID: nil,
            command: "",
            trust: .trusted,
            sanitizedEnvironment: ["TERM": "screen-256color"]
        )
        let codexSurface = BalaganFixtures.surface(
            id: "surface-codex",
            workspaceID: "workspace-split",
            title: "Codex",
            startupCommand: nil,
            resumeBinding: primaryBinding,
            scrollbackSnapshot: "$ codex resume codex-session-123",
            agentLaunchMetadata: AgentLaunchMetadata(
                agentName: "codex",
                startupCommand: "balagan-agent codex",
                cwd: "/tmp/balagan",
                launchedAtMs: 1_700_000_123_000,
                wrapperPath: "/tmp/balagan-agent"
            )
        )
        let shellSurface = BalaganFixtures.surface(
            id: "surface-shell",
            workspaceID: "workspace-split",
            title: "Shell",
            startupCommand: nil,
            resumeBinding: secondaryBinding,
            scrollbackSnapshot: "$ tmux attach"
        )
        let workspace = Workspace(
            id: "workspace-split",
            taskID: "task-split",
            layout: .split(
                axis: .horizontal,
                children: [
                    .surface(codexSurface.id),
                    .split(axis: .vertical, children: [
                        .surface(shellSurface.id),
                    ]),
                ]
            ),
            selectedSurfaceID: shellSurface.id,
            surfaces: [codexSurface, shellSurface],
            lastOpenedAt: BalaganFixtures.laterDate
        )
        let task = BalaganFixtures.task(id: "task-split", workspace: workspace)
        let snapshot = BoardSnapshot(
            savedAt: BalaganFixtures.laterDate,
            boardState: BoardState(
                projects: [BalaganFixtures.project()],
                tasks: [task],
                workspaces: [workspace]
            ),
            uiState: PersistedUIState(
                selectedProjectID: task.projectID,
                selectedTaskID: task.id,
                selectedWorkspaceID: workspace.id,
                selectedSurfaceID: shellSurface.id
            )
        )

        let jsonData = try BoardSnapshot.jsonEncoder().encode(snapshot)
        let jsonLoaded = try BoardSnapshot.jsonDecoder().decode(BoardSnapshot.self, from: jsonData)

        XCTAssertEqual(jsonLoaded, snapshot)
        XCTAssertEqual(jsonLoaded.uiState.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(jsonLoaded.uiState.selectedSurfaceID, shellSurface.id)
        XCTAssertEqual(jsonLoaded.boardState.workspaces.first?.layout, workspace.layout)
        XCTAssertEqual(jsonLoaded.boardState.workspaces.first?.surfaces.map(\.resumeBinding), [primaryBinding, secondaryBinding])
        XCTAssertEqual(jsonLoaded.boardState.workspaces.first?.surfaces.first?.agentLaunchMetadata?.captureStartedAtMs, 1_700_000_123_000)

        let sqliteStore = SQLiteBoardStateStore(url: temporaryDirectory().appendingPathComponent("Balagan.sqlite"))
        try sqliteStore.save(snapshot)
        let sqliteLoaded = try sqliteStore.load()

        XCTAssertEqual(sqliteLoaded, snapshot)
        XCTAssertEqual(sqliteLoaded.uiState.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(sqliteLoaded.uiState.selectedSurfaceID, shellSurface.id)
        XCTAssertEqual(sqliteLoaded.boardState.workspaces.first?.surfaces.first?.agentLaunchMetadata?.startupCommand, "balagan-agent codex")
    }

    func testCapturedMetadataRoundTripsThroughJSONAndSQLite() throws {
        let binding = BalaganFixtures.resumeBinding(
            id: "resume-codex-captured",
            taskID: "task-capture",
            workspaceID: "workspace-capture",
            surfaceID: "surface-codex",
            kind: .agent,
            agentName: "codex",
            sessionID: "codex-session-123",
            command: "codex resume codex-session-123",
            trust: .trusted,
            source: .agentHook,
            pid: 9876,
            executablePath: "/opt/homebrew/bin/codex",
            argv: ["codex"],
            cwd: "/tmp/balagan",
            capturedAt: BalaganFixtures.baseDate,
            captureUpdatedAt: BalaganFixtures.laterDate,
            wasRunning: true,
            isRestorable: true,
            autoResume: true,
            transcriptPath: "/tmp/balagan/transcripts/codex-session-123.log",
            sanitizedEnvironment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        )
        let surface = BalaganFixtures.surface(
            id: "surface-codex",
            workspaceID: "workspace-capture",
            title: "Codex",
            resumeBinding: binding
        )
        let workspace = BalaganFixtures.workspace(
            id: "workspace-capture",
            taskID: "task-capture",
            selectedSurfaceID: surface.id,
            surfaces: [surface]
        )
        let task = BalaganFixtures.task(id: "task-capture", workspace: workspace)
        let snapshot = BoardSnapshot(
            savedAt: BalaganFixtures.laterDate,
            boardState: BoardState(
                projects: [BalaganFixtures.project()],
                tasks: [task],
                workspaces: [workspace]
            )
        )

        let jsonData = try BoardSnapshot.jsonEncoder().encode(snapshot)
        let jsonLoaded = try BoardSnapshot.jsonDecoder().decode(BoardSnapshot.self, from: jsonData)

        XCTAssertEqual(jsonLoaded, snapshot)
        let jsonBinding = try XCTUnwrap(jsonLoaded.boardState.tasks.first?.workspace.surfaces.first?.resumeBinding)
        XCTAssertEqual(jsonBinding.source, .agentHook)
        XCTAssertEqual(jsonBinding.pid, 9876)
        XCTAssertEqual(jsonBinding.executablePath, "/opt/homebrew/bin/codex")
        XCTAssertEqual(jsonBinding.argv, ["codex"])
        XCTAssertEqual(jsonBinding.cwd, "/tmp/balagan")
        XCTAssertEqual(jsonBinding.capturedAt, BalaganFixtures.baseDate)
        XCTAssertEqual(jsonBinding.captureUpdatedAt, BalaganFixtures.laterDate)
        XCTAssertTrue(jsonBinding.wasRunning)
        XCTAssertTrue(jsonBinding.isRestorable)
        XCTAssertTrue(jsonBinding.autoResume)
        XCTAssertEqual(jsonBinding.transcriptPath, "/tmp/balagan/transcripts/codex-session-123.log")

        let sqliteStore = SQLiteBoardStateStore(url: temporaryDirectory().appendingPathComponent("Balagan.sqlite"))
        try sqliteStore.save(snapshot)
        let sqliteLoaded = try sqliteStore.load()

        XCTAssertEqual(sqliteLoaded, snapshot)
        XCTAssertEqual(sqliteLoaded.boardState.tasks.first?.workspace.surfaces.first?.resumeBinding?.source, .agentHook)
    }

    func testLegacySnapshotWithoutCaptureFieldsDecodesWithDefaults() throws {
        let snapshot = BoardSnapshot(
            savedAt: BalaganFixtures.laterDate,
            boardState: BalaganFixtures.boardState()
        )
        let data = try BoardSnapshot.jsonEncoder().encode(snapshot)
        let legacyData = try removingResumeCaptureFields(from: data)

        let loaded = try BoardSnapshot.jsonDecoder().decode(BoardSnapshot.self, from: legacyData)
        let binding = try XCTUnwrap(loaded.boardState.tasks.first?.workspace.surfaces.first?.resumeBinding)

        XCTAssertEqual(binding.source, .manual)
        XCTAssertNil(binding.taskID)
        XCTAssertNil(binding.workspaceID)
        XCTAssertNil(binding.pid)
        XCTAssertNil(binding.executablePath)
        XCTAssertEqual(binding.argv, [])
        XCTAssertNil(binding.cwd)
        XCTAssertNil(binding.capturedAt)
        XCTAssertNil(binding.captureUpdatedAt)
        XCTAssertFalse(binding.wasRunning)
        XCTAssertTrue(binding.isRestorable)
        XCTAssertFalse(binding.isStale)
        XCTAssertFalse(binding.autoResume)
        XCTAssertNil(binding.transcriptPath)
    }

    func testSQLiteStoreRejectsUnsupportedSchemaVersionOnSave() throws {
        let store = SQLiteBoardStateStore(url: temporaryDirectory().appendingPathComponent("Balagan.sqlite"))
        let snapshot = BoardSnapshot(
            schemaVersion: BoardSnapshot.currentSchemaVersion + 1,
            savedAt: BalaganFixtures.baseDate,
            boardState: BalaganFixtures.boardState()
        )

        XCTAssertThrowsError(try store.save(snapshot)) { error in
            XCTAssertEqual(error as? BoardStateStoreError, .unsupportedSchemaVersion(BoardSnapshot.currentSchemaVersion + 1))
        }
    }

    func testUnsupportedSchemaVersionIsRejectedOnSave() throws {
        let store = BoardStateFileStore(url: temporaryDirectory().appendingPathComponent("Balagan.state.json"))
        let snapshot = BoardSnapshot(
            schemaVersion: BoardSnapshot.currentSchemaVersion + 1,
            savedAt: BalaganFixtures.baseDate,
            boardState: BalaganFixtures.boardState()
        )

        XCTAssertThrowsError(try store.save(snapshot)) { error in
            XCTAssertEqual(error as? BoardStateStoreError, .unsupportedSchemaVersion(BoardSnapshot.currentSchemaVersion + 1))
        }
    }

    func testUnsupportedSchemaVersionIsRejectedOnLoad() throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("Balagan.state.json")
        try """
        {
          "schemaVersion": 999,
          "savedAt": "2026-05-29T12:00:00Z",
          "boardState": {
            "projects": [],
            "tasks": [],
            "workspaces": []
          },
          "uiState": {}
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = BoardStateFileStore(url: url)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? BoardStateStoreError, .unsupportedSchemaVersion(999))
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BalaganCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removingResumeCaptureFields(from data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        let stripped = stripResumeCaptureFields(from: object)
        return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
    }

    private func stripResumeCaptureFields(from object: Any) -> Any {
        let captureKeys: Set<String> = [
            "taskID",
            "workspaceID",
            "source",
            "pid",
            "executablePath",
            "argv",
            "cwd",
            "capturedAt",
            "captureUpdatedAt",
            "wasRunning",
            "isRestorable",
            "isStale",
            "autoResume",
            "transcriptPath",
        ]

        if let dictionary = object as? [String: Any] {
            let isResumeBinding = dictionary["surfaceID"] != nil
                && dictionary["kind"] != nil
                && dictionary["command"] != nil
                && dictionary["trust"] != nil
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                guard !isResumeBinding || !captureKeys.contains(pair.key) else {
                    return
                }
                result[pair.key] = stripResumeCaptureFields(from: pair.value)
            }
        }

        if let array = object as? [Any] {
            return array.map(stripResumeCaptureFields)
        }

        return object
    }
}
