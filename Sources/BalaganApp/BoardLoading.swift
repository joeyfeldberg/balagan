import Foundation
import BalaganCore

/// Constructing a `BoardViewModel` at launch: resolving the source (fixture file / state file /
/// SQLite / built-in fixture / empty), applying launch-time env overrides, and deriving agent-launch
/// metadata for a surface. Extracted from `BoardViewModel`.
extension BoardViewModel {
    func agentLaunchMetadata(startupCommand: String?, cwd: String) -> AgentLaunchMetadata? {
        guard let startupCommand = startupCommand?.nilIfBlank,
              startupCommand.contains("balagan-agent"),
              startupCommand.contains("codex")
        else {
            return nil
        }

        let nowMs = Date().millisecondsSince1970
        return AgentLaunchMetadata(
            agentName: "codex",
            startupCommand: startupCommand,
            cwd: cwd,
            launchedAtMs: nowMs,
            wrapperPath: agentWrapperPath
        )
    }

    static func load(options: LaunchOptions) -> BoardViewModel {
        func applyLaunchOverrides(_ viewModel: BoardViewModel) -> BoardViewModel {
            // No real gh subprocesses under ui-test-mode; seeded PR data still renders.
            viewModel.pullRequestTrackingEnabled = (options.uiTestMode == false)
            viewModel.usageTrackingEnabled = (options.uiTestMode == false)
            // Nor any real desktop banners (a snapshot run must not buzz Notification Centre).
            viewModel.agentNotificationsEnabled = (options.uiTestMode == false)
            // Nor reads of the user's real transcripts for the card previews; then prime them once.
            viewModel.transcriptPreviewsEnabled = (options.uiTestMode == false)
            viewModel.synchronousGitReads = options.uiTestMode
            viewModel.tracksLiveTerminals = (options.uiTestMode == false)
            viewModel.refreshAllLastResponses()
            if let rawScale = ProcessInfo.processInfo.environment["BALAGAN_INITIAL_UI_SCALE"],
               let scale = Double(rawScale) {
                viewModel.updateUIScale(scale)
            }
            // Auto-delete archived tasks past their retention window, once per launch.
            viewModel.pruneExpiredArchivedTasks()
            if ProcessInfo.processInfo.environment["BALAGAN_SHOW_ARCHIVED"] == "1" {
                viewModel.showArchived()
            }
            if ProcessInfo.processInfo.environment["BALAGAN_SHOW_COMMAND_PALETTE"] == "1" {
                viewModel.showingCommandPalette = true
            }
            if ProcessInfo.processInfo.environment["BALAGAN_SHOW_CHANGES"] == "1" {
                viewModel.showingChangesView = true
            }
            if ProcessInfo.processInfo.environment["BALAGAN_SHOW_READER"] == "1" {
                viewModel.showingReaderMode = true
            }
            if let rawTheme = ProcessInfo.processInfo.environment["BALAGAN_READER_THEME"],
               let theme = ReaderTheme(rawValue: rawTheme) {
                viewModel.setReaderTheme(theme)
            }
            if ProcessInfo.processInfo.environment["BALAGAN_FAKE_PR"] == "1" {
                viewModel.seedFakePullRequestForSnapshot()
            }
            if ProcessInfo.processInfo.environment["BALAGAN_FIXTURE_USAGE"] == "1" {
                viewModel.seedUsageForSnapshot()
            }
            if ProcessInfo.processInfo.environment["BALAGAN_FIXTURE_AGENT_STATES"] == "1" {
                viewModel.seedAgentStatesForSnapshot()
            }
            return viewModel
        }

        if let fixturePath = options.fixturePath,
           let fixture = try? FixtureDocument.load(from: fixturePath) {
            return applyLaunchOverrides(fixture.makeViewModel(agentWrapperPath: options.agentWrapperPath, dataSource: "fixture"))
        }

        if let statePath = options.statePath,
           FileManager.default.fileExists(atPath: statePath.path),
           let snapshot = try? BoardStateFileStore(url: statePath).load() {
            return applyLaunchOverrides(BoardViewModel(snapshot: snapshot, agentWrapperPath: options.agentWrapperPath, dataSource: "statePath"))
        }

        if let databasePath = options.databasePath,
           let snapshot = try? SQLiteBoardStateStore(url: databasePath).loadLatest() {
            return applyLaunchOverrides(BoardViewModel(snapshot: snapshot, agentWrapperPath: options.agentWrapperPath, dataSource: "sqlite"))
        }

        guard options.uiTestMode || options.fixtureNameWasExplicit else {
            return applyLaunchOverrides(emptyBoard(agentWrapperPath: options.agentWrapperPath, dataSource: "empty"))
        }

        return applyLaunchOverrides(fixture(named: options.fixtureName))
    }

    private static func fixture(named name: String) -> BoardViewModel {
        let seed = BoardFixtures.seed(named: name)
        return BoardViewModel(
            projects: seed.projects,
            tasks: seed.tasks,
            selectedTaskID: seed.selectedTaskID,
            dataSource: "builtInFixture"
        )
    }

    private static func emptyBoard(agentWrapperPath: String? = nil, dataSource: String) -> BoardViewModel {
        BoardViewModel(
            projects: [],
            tasks: [],
            selectedTaskID: nil,
            agentWrapperPath: agentWrapperPath,
            dataSource: dataSource
        )
    }
}
