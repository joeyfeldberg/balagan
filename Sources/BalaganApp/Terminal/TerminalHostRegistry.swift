import Foundation
import BalaganCore

extension LibGhosttySurfaceSize {
    var artifactPayload: [String: Any] {
        [
            "columns": Int(columns),
            "rows": Int(rows),
            "widthPx": Int(widthPx),
            "heightPx": Int(heightPx),
            "cellWidthPx": Int(cellWidthPx),
            "cellHeightPx": Int(cellHeightPx),
        ]
    }
}

final class TerminalHostRegistry: @unchecked Sendable {
    static let shared = TerminalHostRegistry()

    private let lock = NSLock()
    private var hosts: [TerminalHostKey: LibGhosttyTerminalHostView] = [:]
    private weak var currentActiveHost: LibGhosttyTerminalHostView?

    /// Set once at launch with the view model in scope; lets a terminal host report
    /// libghostty-sourced title/cwd changes without threading a closure through every view layer.
    var surfaceMetadataReporter: ((TaskItem.ID, Surface.ID, String?, String?) -> Void)?

    /// Set once at launch; persists a split's divider weights after a drag (keyed by split key).
    var splitWeightReporter: ((TaskItem.ID, String, [Double]) -> Void)?

    /// Set once at launch; flags a surface as "needs attention" when an agent finishes/notifies while
    /// that surface isn't focused (drives the tab/task/project highlights).
    var surfaceAttentionReporter: ((TaskItem.ID, Surface.ID) -> Void)?

    /// Set once at launch; clears a surface's attention highlight when the user focuses it.
    var surfaceFocusReporter: ((TaskItem.ID, Surface.ID) -> Void)?

    /// Set once at launch; reports what a surface's terminal title says about the agent (working /
    /// blocked / idle — a transition, not per animation frame). Feeds
    /// `BoardViewModel.updateTitleSignal`, which the lifecycle reconciler uses to corroborate Claude's
    /// hook state and to derive Codex's outright.
    var surfaceTitleSignalReporter: ((TaskItem.ID, Surface.ID, AgentTitleHeuristic.TitleSignal) -> Void)?

    /// Set once at launch; answers whether a surface is an agent terminal. Gates notifications/attention
    /// so a plain shell (a service emitting a bell or an OSC-9 desktop notification) doesn't raise them.
    var surfaceIsAgentReporter: ((TaskItem.ID, Surface.ID) -> Bool)?

    /// Set once at launch; clears a surface's one-time setup command after it has run on first launch.
    var surfaceSetupConsumedReporter: ((TaskItem.ID, Surface.ID) -> Void)?
    /// The set of tasks that have at least one live terminal, reported (on main) whenever a host is
    /// created or freed. Drives the "not running" state on cards and in the sidebar.
    var liveTasksReporter: ((Set<TaskItem.ID>) -> Void)?
    /// A terminal's process just started (a fresh launch, a resume, a restart).
    var surfaceLaunchedReporter: ((TaskItem.ID, Surface.ID) -> Void)?
    /// ⏎ pressed in a terminal whose process has exited — "resume it" when an agent tab offers it.
    var exitedSurfaceReturnReporter: ((TaskItem.ID, Surface.ID) -> Void)?

    /// Posts the current live-task set. Call after any change to `hosts`, outside the lock.
    private func reportLiveTasks() {
        lock.lock()
        let live = Set(hosts.keys.map(\.taskID))
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.liveTasksReporter?(live)
        }
    }

    private init() {}

    @MainActor
    func host(for key: TerminalHostKey) -> LibGhosttyTerminalHostView {
        lock.lock()
        if let host = hosts[key] {
            lock.unlock()
            return host
        }
        lock.unlock()

        let host = LibGhosttyTerminalHostView()

        lock.lock()
        let existingHost = hosts[key]
        if existingHost == nil {
            hosts[key] = host
        }
        lock.unlock()
        if existingHost == nil { reportLiveTasks() }

        return existingHost ?? host
    }

    func close(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let key = TerminalHostKey(taskID: taskID, surfaceID: surfaceID)

        lock.lock()
        let host = hosts.removeValue(forKey: key)
        if let host, currentActiveHost === host {
            currentActiveHost = nil
        }
        lock.unlock()
        reportLiveTasks()

        DispatchQueue.main.async {
            host?.closeTerminalSession()
        }
    }

    @MainActor
    func focus(taskID: TaskItem.ID, surfaceID: Surface.ID) {
        let key = TerminalHostKey(taskID: taskID, surfaceID: surfaceID)

        lock.lock()
        let host = hosts[key]
        lock.unlock()

        host?.requestUserFocus()
    }

    @MainActor
    func resume(_ config: TerminalSessionConfig, command: ResumeLaunchCommand) {
        let host = self.host(for: config.sessionKey)
        host.launchConfirmedResume(config, command: command)
        host.requestUserFocus()
    }

    /// Imperatively creates (if needed) and launches a surface's terminal **off-screen** — the
    /// fresh-launch sibling of `resume(...)`. Used to start a task's agent in the background
    /// (`create --eager`) so an orchestrator can message it without the task ever being selected.
    /// Mirrors what the SwiftUI view does on mount; when the task is later opened, `configure`'s guard
    /// attaches to this already-live session instead of relaunching. Must run on the main actor. It
    /// deliberately does not focus the surface (unlike `resume`) — background work shouldn't steal focus.
    @MainActor
    func launch(_ config: TerminalSessionConfig) {
        let host = self.host(for: config.sessionKey)
        host.configure(config)
    }

    /// Restarts an agent in place: tears the current surface down and re-configures the **same** host, so
    /// a visible tab stays mounted. `configure` re-runs the surface's launch — resuming its session from
    /// the `ResumeBinding` (or re-running its startup command). The caller SIGTERMs the old process first;
    /// freeing the surface alone doesn't reliably reap it.
    @MainActor
    func restart(_ config: TerminalSessionConfig) {
        let host = self.host(for: config.sessionKey)
        host.stopTerminal()
        host.configure(config)
        host.requestUserFocus()
    }

    /// Synchronously detaches the notification/bell callbacks of every live host for a task. Sleep
    /// calls this *before* SIGTERM-ing the agents so a dying agent's final bell/desktop-notification
    /// escape lands on nil callbacks instead of posting a banner or flagging the slept task. Because
    /// both this and the event trampoline run on the main queue, muting here (on the main actor,
    /// start-to-finish before sleep returns) is guaranteed to precede any queued event block.
    @MainActor
    func muteEventCallbacks(taskID: TaskItem.ID) {
        lock.lock()
        let taskHosts = hosts.filter { $0.key.taskID == taskID }.map(\.value)
        lock.unlock()
        for host in taskHosts {
            host.muteEventCallbacks()
        }
    }

    /// The live host for a terminal, if one exists — never creates one (unlike `host(for:)`).
    func existingHost(taskID: TaskItem.ID, surfaceID: Surface.ID) -> LibGhosttyTerminalHostView? {
        lock.lock()
        defer { lock.unlock() }
        return hosts[TerminalHostKey(taskID: taskID, surfaceID: surfaceID)]
    }

    /// Whether any live terminal host exists for the task (i.e. there's something to sleep/free).
    func hasHosts(taskID: TaskItem.ID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hosts.keys.contains { $0.taskID == taskID }
    }

    /// Whether a terminal has something besides its shell prompt running — Ghostty's own close-confirm
    /// check. False when there's no live host (nothing running) or its process already exited. Main
    /// thread (it touches the host's surface).
    @MainActor
    func terminalIsBusy(taskID: TaskItem.ID, surfaceID: Surface.ID) -> Bool {
        lock.lock()
        let host = hosts[TerminalHostKey(taskID: taskID, surfaceID: surfaceID)]
        lock.unlock()
        guard let handle = host?.surfaceHandle else { return false }
        if handle.processHasExited() { return false }
        return handle.needsConfirmQuit()
    }

    func closeTask(taskID: TaskItem.ID) {
        lock.lock()
        let removedHosts = hosts
            .filter { $0.key.taskID == taskID }
            .map(\.value)
        hosts = hosts.filter { $0.key.taskID != taskID }
        if let activeHost = currentActiveHost,
           removedHosts.contains(where: { $0 === activeHost }) {
            currentActiveHost = nil
        }
        lock.unlock()
        reportLiveTasks()

        DispatchQueue.main.async {
            for host in removedHosts {
                host.closeTerminalSession()
            }
        }
    }

    func setActiveHost(_ host: LibGhosttyTerminalHostView) {
        lock.lock()
        defer { lock.unlock() }

        currentActiveHost = host
    }

    func clearActiveHost(_ host: LibGhosttyTerminalHostView) {
        lock.lock()
        defer { lock.unlock() }

        if currentActiveHost === host {
            currentActiveHost = nil
        }
    }

    func activeHost() -> LibGhosttyTerminalHostView? {
        lock.lock()
        defer { lock.unlock() }

        return currentActiveHost
    }

    @MainActor
    func performSharedFontZoomShortcut(action: String, evidenceName: String, appFontSize: Float) {
        lock.lock()
        let activeHost = currentActiveHost
        let entries = hosts.map { ($0.key, $0.value) }
        lock.unlock()

        let beforeURL = activeHost?.recordFontZoomSnapshot(evidenceName: evidenceName, phase: "before")
        let results = entries.compactMap { key, host -> TerminalFontZoomHostResult? in
            guard let result = host.performFontZoomBindingAction(action: action) else {
                return nil
            }
            return TerminalFontZoomHostResult(
                taskID: key.taskID,
                surfaceID: key.surfaceID,
                handled: result.handled,
                beforeSize: result.beforeSize,
                afterSize: result.afterSize
            )
        }
        let afterURL = activeHost?.recordFontZoomSnapshot(evidenceName: evidenceName, phase: "after")

        activeHost?.recordSharedFontZoomEvidence(
            evidenceName: evidenceName,
            action: action,
            appFontSize: appFontSize,
            beforeURL: beforeURL,
            afterURL: afterURL,
            hostResults: results
        )
    }

    @MainActor
    func visibleTextSnapshots(fresh: Bool) -> [TerminalVisibleTextSnapshot] {
        lock.lock()
        let entries = hosts.map { ($0.key, $0.value) }
        lock.unlock()

        return entries.compactMap { key, host in
            guard let text = host.visibleTextSnapshot(fresh: fresh), text.isEmpty == false else {
                return nil
            }
            return TerminalVisibleTextSnapshot(
                taskID: key.taskID,
                surfaceID: key.surfaceID,
                text: text
            )
        }
    }
}
