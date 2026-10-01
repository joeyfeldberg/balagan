import AppKit
import BalaganCore

extension LibGhosttyTerminalHostView {
    func reportSurfaceTitle(_ title: String) {
        guard let sessionKey = currentSessionKey else { return }

        // Passive working-state read: Claude/Codex prefix the title with an animated spinner glyph while
        // working, and Codex names its blocked state ("Action Required") there too (see
        // AgentTitleHeuristic). Report only the transitions — the spinner animates several times a second
        // but the *state* changes rarely, and this must not be gated by the cleaned-title guard below
        // (which strips the spinner, so the cleaned title is unchanged). A blank title says nothing, so
        // it leaves the last reading standing.
        if let signal = AgentTitleHeuristic.classify(title: title), signal != lastReportedTitleSignal {
            lastReportedTitleSignal = signal
            TerminalHostRegistry.shared.surfaceTitleSignalReporter?(sessionKey.taskID, sessionKey.surfaceID, signal)
        }

        let cleaned = cleanedTabTitle(title)
        guard cleaned.isEmpty == false, cleaned != lastReportedTitle else {
            return
        }

        lastReportedTitle = cleaned
        TerminalHostRegistry.shared.surfaceMetadataReporter?(sessionKey.taskID, sessionKey.surfaceID, cleaned, nil)
    }

    private func cleanedTabTitle(_ raw: String) -> String {
        // Drop the leading working spinner so the tab label is stable while the agent runs (the animated
        // glyph would otherwise change the title ~10x/s — a model mutation and a flickering tab each time).
        var title = AgentTitleHeuristic.strippingSpinner(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        // Many shells set the OSC title to "user@host:path"; drop that prefix.
        if let colon = title.firstIndex(of: ":"),
           title[title.startIndex..<colon].contains("@") {
            title = String(title[title.index(after: colon)...])
        }

        // If what remains is a path, show only its last component.
        if title.contains("/") {
            let withoutTrailingSlash = title.hasSuffix("/") ? String(title.dropLast()) : title
            if let last = withoutTrailingSlash.split(separator: "/").last {
                title = String(last)
            }
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reportSurfaceWorkingDirectory(_ pwd: String) {
        let path = normalizedWorkingDirectory(pwd)
        guard path.isEmpty == false,
              path != lastReportedWorkingDirectory,
              let sessionKey = currentSessionKey
        else {
            return
        }

        lastReportedWorkingDirectory = path
        TerminalHostRegistry.shared.surfaceMetadataReporter?(sessionKey.taskID, sessionKey.surfaceID, nil, path)
    }

    private func normalizedWorkingDirectory(_ value: String) -> String {
        // libghostty reports cwd via OSC 7 as a file URL (e.g. file://host/Users/foo); reduce to a path.
        if value.hasPrefix("file://"), let url = URL(string: value) {
            return url.path
        }
        return value
    }

    func presentDesktopNotification(title: String?, body: String?) {
        // Don't interrupt with a banner for the terminal the user is already looking at.
        let focused = isActive && NSApp.isActive && (window?.isKeyWindow ?? false)
        guard focused == false else {
            return
        }
        // Notifications are for agents. A plain shell running a service can emit an OSC-9 desktop
        // notification (shell "notify when done" integrations, dev tools); that must not post a banner
        // or flag attention.
        guard surfaceIsAgentSurface else { return }

        // Highlight this surface's tab/task/project until the user opens it.
        reportSurfaceNeedsAttention()

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)

        let bannerTitle: String
        let bannerBody: String
        if let cleanTitle, cleanTitle.isEmpty == false, let cleanBody, cleanBody.isEmpty == false {
            bannerTitle = cleanTitle
            bannerBody = cleanBody
        } else {
            let message = [cleanTitle, cleanBody].compactMap { $0 }.first(where: { $0.isEmpty == false })
            guard let message else {
                return
            }
            bannerTitle = lastReportedTitle ?? "Terminal"
            bannerBody = message
        }

        SystemNotificationPresenter.shared.post(
            title: bannerTitle,
            body: bannerBody,
            taskID: currentSessionKey?.taskID,
            surfaceID: currentSessionKey?.surfaceID
        )
    }

    func handleBell() {
        NSSound.beep()
        // An unfocused *agent* terminal's bell (e.g. finishing a turn) highlights its tab. A plain
        // shell's bell just beeps — a service ringing the bell shouldn't flag Balagan attention.
        let focused = isActive && NSApp.isActive && (window?.isKeyWindow ?? false)
        if focused == false, surfaceIsAgentSurface {
            reportSurfaceNeedsAttention()
        }
    }

    /// Whether this surface is an agent terminal (queried from the view model). Notifications/attention
    /// are gated on this so a plain shell running a service can't raise them.
    private var surfaceIsAgentSurface: Bool {
        guard let sessionKey = currentSessionKey else { return false }
        return TerminalHostRegistry.shared.surfaceIsAgentReporter?(sessionKey.taskID, sessionKey.surfaceID) ?? false
    }

    private func reportSurfaceNeedsAttention() {
        guard let sessionKey = currentSessionKey else { return }
        TerminalHostRegistry.shared.surfaceAttentionReporter?(sessionKey.taskID, sessionKey.surfaceID)
    }

    func reportSurfaceFocusedClearingAttention() {
        guard let sessionKey = currentSessionKey else { return }
        TerminalHostRegistry.shared.surfaceFocusReporter?(sessionKey.taskID, sessionKey.surfaceID)
    }

    func requestEndedProcessAutoClose() {
        guard didRequestEndedProcessAutoClose == false,
              let sessionKey = currentSessionKey
        else {
            return
        }

        didRequestEndedProcessAutoClose = true
        writeEndedProcessAutoCloseArtifact(sessionKey: sessionKey)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.onEndedProcessSurface?(sessionKey.taskID, sessionKey.surfaceID)
        }
    }
}
