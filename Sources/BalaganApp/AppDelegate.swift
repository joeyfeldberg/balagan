import AppKit
import Combine
import SwiftUI
import BalaganCore

@main
final class BalaganApplication: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var window: NSWindow?
    var viewModel: BoardViewModel?
    var launchOptions: LaunchOptions?
    var autosaver: BoardAutosaver?
    var periodicSaveTimer: Timer?
    var pullRequestPollTimer: Timer?
    var lifecycleReconcileTimer: Timer?
    var usagePollTimer: Timer?
    var usageWatcher: DispatchSourceFileSystemObject?
    var autoSleepTimer: Timer?
    var memoryPressureSource: DispatchSourceMemoryPressure?
    var taskActivityCancellable: AnyCancellable?
    var autosaveCancellable: AnyCancellable?
    var shortcutsCancellable: AnyCancellable?
    var waitingBannerRearmCancellable: AnyCancellable?
    var appResignActiveObserver: NSObjectProtocol?
    var sessionReportServer: SessionReportServer?
    var controlServer: ControlSocketServer?
    /// The resolved terminal backend, stored so the control socket can launch a task's agent surface
    /// off-screen (CLI `create --eager`) without a SwiftUI view in scope to supply it.
    var terminalRuntime: TerminalRuntimeOptions?

    static func main() {
        let app = NSApplication.shared
        let delegate = BalaganApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(CommandLine.arguments)
        launchOptions = options
        if options.uiTestMode == false {
            // Before anything reads preferences or the database: carry over the TaskBoard-era data.
            _ = LegacyTaskBoardMigration.run()
        }
        installMenus()
        TerminalScrollbackReplay.reset()

        if options.uiTestMode == false {
            // Custom agents (~/.balagan/agents/*.json) join the built-ins, and every agent gets its
            // shim + integration files, so typing an agent at any Balagan prompt is integrated.
            AgentProfiles.all = AgentProfiles.loadCustom()
            if options.agentWrapperPath != nil {
                AgentIntegrationInstaller.install(profiles: AgentProfiles.all)
            }
        }

        let viewModel = BoardViewModel.load(options: options)
        self.viewModel = viewModel
        autosaver = makeAutosaver(options: options, viewModel: viewModel)

        wireTerminalHostReporters(viewModel: viewModel)
        wireAutosaveAndShortcuts(viewModel: viewModel)
        wireWaitingBannerRearm(viewModel: viewModel)
        if viewModel.recoveredCodexSurfaceCount > 0 {
            persistBoardState()
        }

        startSessionReportServer(options: options, viewModel: viewModel)
        startControlServer(options: options, viewModel: viewModel)
        installControlCLISymlinkIfPossible(options: options)
        if options.uiTestMode == false {
            SystemNotificationPresenter.shared.onActivateSurface = { [weak self] taskID, surfaceID in
                self?.focusSurfaceFromNotification(taskID: taskID, surfaceID: surfaceID)
            }
            SystemNotificationPresenter.shared.configure()
            startPeriodicScrollbackSaves()
            startPullRequestPolling()
            startLifecycleReconcile()
            startUsagePolling()
            startAutoSleep(viewModel: viewModel)
            viewModel.detectInstalledAgents()
        }

        let terminalRuntime = TerminalRuntimeOptions(options: options)
        self.terminalRuntime = terminalRuntime
        viewModel.agentRelauncher = { [weak viewModel, weak self] taskID, surfaceID in
            guard let viewModel else { return }
            MainActor.assumeIsolated {
                _ = TerminalRestart.restart(
                    taskID: taskID,
                    surfaceID: surfaceID,
                    viewModel: viewModel,
                    runtime: terminalRuntime,
                    artifactDirectory: self?.launchOptions?.artifactDirectory
                )
            }
        }
        if options.uiTestMode == false {
            adoptGhosttyConfigFontSize(viewModel: viewModel, runtime: terminalRuntime)
            configureWorktreeResolver(viewModel: viewModel, runtime: terminalRuntime)
        }

        let rootView = BoardScreen(
            viewModel: viewModel,
            artifactDirectory: options.artifactDirectory,
            terminalRuntime: terminalRuntime
        )
            .frame(minWidth: 1120, minHeight: 760)

        let window = makeMainWindow(rootView: rootView, viewModel: viewModel)
        self.window = window
        persistBoardState()
        runLaunchTimeArtifactsAndSmokes(options: options, viewModel: viewModel, window: window)
    }

    @MainActor
    private func installMenus() {
        NSApp.applicationIconImage = AppIcon.make()
        AppMenu.install()
        installTerminalMenu()
    }

    @MainActor
    private func wireTerminalHostReporters(viewModel: BoardViewModel) {
        TerminalHostRegistry.shared.surfaceMetadataReporter = { [weak viewModel] taskID, surfaceID, title, cwd in
            viewModel?.updateSurfaceMetadata(taskID: taskID, surfaceID: surfaceID, title: title, cwd: cwd)
        }
        TerminalHostRegistry.shared.splitWeightReporter = { [weak viewModel] taskID, key, weights in
            viewModel?.setSplitWeights(taskID: taskID, key: key, weights: weights)
        }
        TerminalHostRegistry.shared.surfaceAttentionReporter = { [weak viewModel] taskID, surfaceID in
            viewModel?.flagSurfaceNeedsAttention(taskID: taskID, surfaceID: surfaceID)
        }
        TerminalHostRegistry.shared.surfaceFocusReporter = { [weak viewModel] taskID, surfaceID in
            viewModel?.clearSurfaceAttention(taskID: taskID, surfaceID: surfaceID)
        }
        TerminalHostRegistry.shared.surfaceTitleSignalReporter = { [weak viewModel] taskID, surfaceID, signal in
            viewModel?.updateTitleSignal(taskID: taskID, surfaceID: surfaceID, signal: signal)
        }
        TerminalHostRegistry.shared.surfaceIsAgentReporter = { [weak viewModel] taskID, surfaceID in
            viewModel?.surfaceIsAgentTerminal(taskID: taskID, surfaceID: surfaceID) ?? false
        }
        TerminalHostRegistry.shared.surfaceSetupConsumedReporter = { [weak viewModel] taskID, surfaceID in
            viewModel?.consumeSetupCommand(taskID: taskID, surfaceID: surfaceID)
        }
        TerminalHostRegistry.shared.surfaceLaunchedReporter = { [weak viewModel] taskID, surfaceID in
            viewModel?.noteSurfaceLaunched(taskID: taskID, surfaceID: surfaceID)
        }
        TerminalHostRegistry.shared.exitedSurfaceReturnReporter = { [weak viewModel] taskID, surfaceID in
            viewModel?.resumeEndedAgent(taskID: taskID, surfaceID: surfaceID)
        }
        TerminalHostRegistry.shared.liveTasksReporter = { [weak viewModel] live in
            if viewModel?.liveTaskIDs != live { viewModel?.liveTaskIDs = live }
        }
        viewModel.backgroundTaskWaker = { [weak self] taskID in
            MainActor.assumeIsolated { self?.launchTaskInBackground(taskID: taskID) }
        }
    }

    /// A waiting banner armed while the user was looking at the surface is dropped when it fires; this
    /// re-arms it (once per waiting episode) the moment they look away — a task/tab switch or Balagan
    /// going to the background. See `BoardViewModel.rearmWaitingBannersAfterFocusChange`.
    @MainActor
    private func wireWaitingBannerRearm(viewModel: BoardViewModel) {
        waitingBannerRearmCancellable = viewModel.$selectedTaskID
            .combineLatest(viewModel.$selectedSurfaceID)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _, _ in
                viewModel?.rearmWaitingBannersAfterFocusChange()
            }
        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak viewModel] _ in
            MainActor.assumeIsolated { viewModel?.rearmWaitingBannersAfterFocusChange() }
        }
    }

    @MainActor
    private func wireAutosaveAndShortcuts(viewModel: BoardViewModel) {
        // Every model change funnels into the autosaver, which debounces and writes off the main
        // thread — never a save per change, and never a save that mutates the model back.
        autosaveCancellable = viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.autosaver?.noteModelChanged()
            }
        // Rebuild the Terminal menu whenever the user rebinds a shortcut, so its key equivalents
        // always reflect the saved settings. `dropFirst` skips the initial value (already installed).
        shortcutsCancellable = viewModel.$keyboardShortcuts.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.installTerminalMenu()
            }
        }
    }

    @MainActor
    private func configureWorktreeResolver(viewModel: BoardViewModel, runtime: TerminalRuntimeOptions) {
        guard runtime.selection.kind == .libghostty else { return }
        // Only the live terminal path creates real git worktrees; tests/headless leave this nil.
        viewModel.worktreeResolver = { repoPath, worktreesDirectory, branch, baseBranch in
            let directory = worktreesDirectory?.nilIfBlank
                ?? Project.defaultWorktreesDirectory(forRepoPath: repoPath)
            return GitWorktreeManager.ensureWorktree(
                repoPath: repoPath,
                worktreesDirectory: directory,
                branch: branch,
                baseBranch: baseBranch
            )
        }
    }

    @MainActor
    private func makeMainWindow(rootView: some View, viewModel: BoardViewModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Balagan"
        window.center()
        // Dark titlebar to match the app's dark content (and so the titlebar control glyphs read light).
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: rootView)

        // cmux-style titlebar controls next to the traffic lights: hide-sidebar toggle + notification
        // bell that jumps to terminals where an agent finished.
        let titlebarControls = NSTitlebarAccessoryViewController()
        titlebarControls.layoutAttribute = .leading
        let controlsView = NSHostingView(rootView: TitlebarControls(viewModel: viewModel))
        // Fixed width that comfortably fits the toggle + agent-sessions + bell (and their badges)
        // (fittingSize can be 0 before first layout, which would hide the accessory).
        controlsView.frame = NSRect(x: 0, y: 0, width: 116, height: 28)
        titlebarControls.view = controlsView
        window.addTitlebarAccessoryViewController(titlebarControls)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        return window
    }

    @MainActor
    private func runLaunchTimeArtifactsAndSmokes(options: LaunchOptions, viewModel: BoardViewModel, window: NSWindow) {
        writeReadyArtifact(options: options, viewModel: viewModel, window: window)
        recordSelectedResumeIfRequested(options: options, viewModel: viewModel)
        runUIFlowSmokeIfRequested(options: options, viewModel: viewModel)
        runTerminalStateCaptureIfRequested(options: options, viewModel: viewModel)
        runAgentReopenCaptureSmokeIfRequested(options: options, viewModel: viewModel)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Deliberately do NOT stop() the socket servers here. Their stop() cancels a DispatchSource on
        // a background queue, whose cancel handler closes the listen fd. During process termination that
        // async close races with fd reuse elsewhere (e.g. the synchronous autosave below opening the
        // SQLite db onto the just-freed fd number), which trips EXC_GUARD (GUARD_TYPE_FD) — a crash on
        // quit. The teardown is unnecessary at exit anyway: the kernel reaps every fd, and both servers
        // unlink + rebind their socket path on the next launch. So we just let the process exit.
        periodicSaveTimer?.invalidate()
        pullRequestPollTimer?.invalidate()
        lifecycleReconcileTimer?.invalidate()
        autosaver?.flushForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Adopt the user's Ghostty `font-size` as the base terminal size (matching their Ghostty), but
    /// only when they haven't already customized it via zoom. Best-effort: silently keeps the default
    /// if libghostty or the config value is unavailable.
    @MainActor
    private func adoptGhosttyConfigFontSize(viewModel: BoardViewModel, runtime: TerminalRuntimeOptions) {
        guard runtime.selection.kind == .libghostty,
              viewModel.terminalAppearance.fontSize == TerminalAppearanceSettings.defaultFontSize,
              let library = try? LibGhosttyDynamicLibrary.load(explicitPath: runtime.libGhosttyPath)
        else {
            return
        }

        try? library.initializeOnce(arguments: ["Balagan"])

        guard let configuredFontSize = library.configuredFontSize(),
              configuredFontSize >= 6, configuredFontSize <= 72
        else {
            return
        }

        viewModel.terminalAppearance.fontSize = configuredFontSize
    }
}
