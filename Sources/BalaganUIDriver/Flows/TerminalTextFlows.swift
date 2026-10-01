import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    func runTerminalInputFlow() throws {
        try createProject()
        try createTask()
        try openTaskWorkspace(identifier: "task-card-harness-task")

        let terminalIdentifiers = liveTerminalIdentifiers(forTaskID: "harness-task")
        try waitForTerminalHostMounted(surfaceID: "surface-harness-task-main")
        try clickAny(identifiers: terminalIdentifiers)

        let typedOutputURL = artifactDirectory.appendingPathComponent("terminal-input-typed.txt")
        let typedMarker = "BALAGAN_TYPED_INPUT_OK"
        typeOnly("printf \(shellSingleQuoted(typedMarker + "\\n")) > \(shellSingleQuoted(typedOutputURL.path))\n")
        try waitForFile(typedOutputURL, timeout: 10)

        let outputURL = artifactDirectory.appendingPathComponent("terminal-input-output.txt")
        let marker = "BALAGAN_TERMINAL_INPUT_OK"
        typeOnly("export BALAGAN_TAB_STATE_OK=\(marker)\n")
        let firstTabBeforeSwitchURL = artifactDirectory.appendingPathComponent("terminal-input-before-switch.txt")
        pasteOnly("printf 'BALAGAN_FIRST_TAB_BEFORE_SWITCH_OK\\n' > \(shellSingleQuoted(firstTabBeforeSwitchURL.path))\n")
        try waitForFile(firstTabBeforeSwitchURL, timeout: 10)

        try press(identifier: "create-terminal-tab-button")
        try waitForElement(identifier: "terminal-pane-tab-2", timeout: 5)
        let secondTabOutputURL = artifactDirectory.appendingPathComponent("terminal-input-second-tab.txt")
        pasteOnly("printf 'BALAGAN_SECOND_TAB_OK\\n' > \(shellSingleQuoted(secondTabOutputURL.path))\n")
        try waitForFile(secondTabOutputURL, timeout: 10)

        try selectPicker(identifier: "terminal-tab-picker", value: "agent")
        let afterSwitchOutputURL = artifactDirectory.appendingPathComponent("terminal-input-after-switch.txt")
        pasteOnly("printf 'BALAGAN_FIRST_TAB_AFTER_SWITCH_OK\\n' > \(shellSingleQuoted(afterSwitchOutputURL.path))\n")
        try waitForFile(afterSwitchOutputURL, timeout: 10)

        let command = "printf \"$BALAGAN_TAB_STATE_OK\\n\" > \(shellSingleQuoted(outputURL.path))\n"
        pasteOnly(command)
        try waitForFile(outputURL, timeout: 10)

        try finishFlow([
            "terminalIdentifiers": terminalIdentifiers,
            "typedInputOutputPath": typedOutputURL.path,
            "outputPath": outputURL.path,
            "firstTabBeforeSwitchOutputPath": firstTabBeforeSwitchURL.path,
            "afterSwitchOutputPath": afterSwitchOutputURL.path,
            "secondTabOutputPath": secondTabOutputURL.path,
            "typedInputMarker": typedMarker,
            "marker": marker,
            "firstTabBeforeSwitchMarker": "BALAGAN_FIRST_TAB_BEFORE_SWITCH_OK",
            "afterSwitchMarker": "BALAGAN_FIRST_TAB_AFTER_SWITCH_OK",
            "secondTabMarker": "BALAGAN_SECOND_TAB_OK",
            "tabStatePersistence": "completed",
        ])
    }

    func runTerminalManualInputFlow() throws {
        try createProject()
        try createTask()
        try openTaskWorkspace(identifier: "task-card-harness-task")

        let token = uniqueToken()
        let firstTerminalIdentifiers = liveTerminalIdentifiers(forTaskID: "harness-task")
        try waitForTerminalHostMounted(surfaceID: "surface-harness-task-main")

        let openMarker = try typeTouchCommand(
            basename: "tbmanualopen\(token)",
            terminalIdentifiers: firstTerminalIdentifiers
        )

        try press(identifier: "create-terminal-tab-button")
        let secondTerminalIdentifiers = terminalIdentifiers(surfaceID: "tab-2")
        try waitForTerminalHostMounted(surfaceID: "tab-2")
        let secondMarker = try typeTouchCommand(
            basename: "tbmanualsecond\(token)",
            terminalIdentifiers: secondTerminalIdentifiers
        )

        try selectPicker(identifier: "terminal-tab-picker", value: "agent")
        let switchedBackMarker = try typeTouchCommand(
            basename: "tbmanualback\(token)",
            terminalIdentifiers: firstTerminalIdentifiers
        )

        try showProjectTasks()
        try openTaskWorkspace(identifier: "task-card-harness-task")
        try waitForTerminalHostMounted(surfaceID: "surface-harness-task-main")
        let navigationMarker = try typeTouchCommand(
            basename: "tbmanualnav\(token)",
            terminalIdentifiers: firstTerminalIdentifiers
        )

        try finishFlow([
            "terminalIdentifiers": firstTerminalIdentifiers,
            "secondTerminalIdentifiers": secondTerminalIdentifiers,
            "openMarkerPath": openMarker.path,
            "secondTabMarkerPath": secondMarker.path,
            "switchedBackMarkerPath": switchedBackMarker.path,
            "navigationMarkerPath": navigationMarker.path,
            "typingMethod": "physical-key-events",
        ])
    }

    /// One "type a visible token" phase: an optional setup step, then the surface/identifiers to
    /// type into and the evidence name to record under.
    func runTerminalNavigationFlow() throws {
        try createProject()
        try createTask()
        try createTask(title: FlowValues.navigationOtherTaskName)
        try openTaskWorkspace(identifier: "task-card-harness-task")

        let terminalIdentifiers = liveTerminalIdentifiers(forTaskID: "harness-task")
        try waitForTerminalHostMounted(surfaceID: "surface-harness-task-main")
        try clickAny(identifiers: terminalIdentifiers)

        let beforeNavigationURL = artifactDirectory.appendingPathComponent("terminal-navigation-before.txt")
        let afterNavigationURL = artifactDirectory.appendingPathComponent("terminal-navigation-after.txt")
        let marker = "BALAGAN_NAVIGATION_STATE_OK"

        pasteOnly("export BALAGAN_NAV_STATE=\(marker)\n")
        pasteOnly("printf \(shellSingleQuoted("BALAGAN_NAVIGATION_BEFORE_OK\\n")) > \(shellSingleQuoted(beforeNavigationURL.path))\n")
        try waitForFile(beforeNavigationURL, timeout: 10)

        try showProjectTasks()
        try openTaskWorkspace(identifier: "task-card-harness-navigation-other-task")
        try showProjectTasks()
        try openTaskWorkspace(identifier: "task-card-harness-task")
        try waitForTerminalHostMounted(surfaceID: "surface-harness-task-main")
        try clickAny(identifiers: terminalIdentifiers)

        pasteOnly("printf \"$BALAGAN_NAV_STATE\\n\" > \(shellSingleQuoted(afterNavigationURL.path))\n")
        try waitForFile(afterNavigationURL, timeout: 10)

        try finishFlow([
            "terminalIdentifiers": terminalIdentifiers,
            "beforeNavigationOutputPath": beforeNavigationURL.path,
            "afterNavigationOutputPath": afterNavigationURL.path,
            "beforeNavigationMarker": "BALAGAN_NAVIGATION_BEFORE_OK",
            "stateMarker": marker,
            "navigationPersistence": "completed",
        ])
    }

    func runTerminalCloseOpenPromptFlow() throws {
        try createProject()
        try createTask()
        try openTaskWorkspace(identifier: "task-card-harness-task")

        let firstSurfaceID = "surface-harness-task-main"
        let reopenedSurfaceID = "tab-1"
        try waitForTerminalHostMounted(surfaceID: firstSurfaceID)
        try clickAny(identifiers: liveTerminalIdentifiers(forTaskID: "harness-task"))
        try typePhysicalOnly("ls\n")
        try waitForVisibleText(surfaceID: firstSurfaceID, containing: "ls", timeout: 10)

        try deleteOnlyTerminalTab()
        try pressAny(
            identifiers: ["create-terminal-tab-button"],
            titles: ["New Terminal Tab"]
        )
        try waitForElement(identifier: "terminal-pane-\(reopenedSurfaceID)", timeout: 5)
        try waitForTerminalHostMounted(surfaceID: reopenedSurfaceID)
        try waitForCleanPrompt(surfaceID: reopenedSurfaceID, timeout: 10)

        let shellProbe = "__BALAGAN_SHELL__"
        try clickAny(identifiers: terminalIdentifiers(surfaceID: reopenedSurfaceID))
        typeOnly("printf '\(shellProbe)%s\\n' \"$0\"\n")
        let observedShell = try waitForShellProbeOutput(shellProbe, surfaceID: reopenedSurfaceID, timeout: 10)
        let expectedShell = ProcessInfo.processInfo.environment["BALAGAN_EXPECTED_SHELL"]
            ?? ProcessInfo.processInfo.environment["SHELL"]
        if let expectedShell, expectedShell.isEmpty == false {
            let expectedBasename = URL(fileURLWithPath: expectedShell).lastPathComponent
            let observedBasename = URL(fileURLWithPath: observedShell).lastPathComponent
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard observedBasename == expectedBasename else {
                throw DriverError.staleRenderedPixels(
                    "expected default shell \(expectedShell), observed \(observedShell)"
                )
            }
        }

        try finishFlow([
            "typedCommand": "ls",
            "closedSurfaceId": firstSurfaceID,
            "reopenedSurfaceId": reopenedSurfaceID,
            "visibleTextPath": visibleTextURL(surfaceID: reopenedSurfaceID).path,
            "forbiddenPromptSuffixPattern": "[$%#>] sNNN",
            "expectedShell": expectedShell ?? NSNull(),
            "observedShell": observedShell,
        ])
    }

    func runTerminalReloadPromptFlow() throws {
        let surfaceID = "surface-reload-prompt"
        try waitForElement(identifier: "task-terminal-workspace", timeout: 10)
        try waitForElement(identifier: "terminal-pane-\(surfaceID)", timeout: 5)
        try waitForTerminalHostMounted(surfaceID: surfaceID)
        try waitForVisibleText(surfaceID: surfaceID, containing: "FAKE_CODEX_ARGS:resume:s018", timeout: 10)

        let visibleText = try readVisibleText(surfaceID: surfaceID)
        let leakedPromptLines = visibleText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                line.contains("$ s018") || line.contains("% s018") || line.contains("> s018")
            }

        guard leakedPromptLines.isEmpty else {
            throw DriverError.staleRenderedPixels(
                "resume session suffix leaked into terminal prompt input: \(leakedPromptLines.joined(separator: " | "))"
            )
        }

        try finishFlow([
            "surfaceId": surfaceID,
            "visibleTextPath": visibleTextURL(surfaceID: surfaceID).path,
            "resumeOutputToken": "FAKE_CODEX_ARGS:resume:s018",
            "forbiddenPromptSuffixes": ["$ s018", "% s018", "> s018"],
        ])
    }

    func runTerminalEndedAutocloseFlow() throws {
        let surfaceID = "surface-ended-autoclose"
        let autoCloseURL = artifactDirectory.appendingPathComponent(
            "libghostty-terminal-ended-process-autoclose-\(surfaceID.safeArtifactComponent).json"
        )

        try waitForElement(identifier: "task-terminal-workspace", timeout: 10)
        try waitForFile(autoCloseURL, timeout: 15)
        try waitForElement(identifier: "empty-terminal-workspace", timeout: 5)
        try waitForElementToDisappear(identifier: "terminal-pane-\(surfaceID)", timeout: 1)

        try finishFlow([
            "closedSurfaceId": surfaceID,
            "autoCloseArtifact": autoCloseURL.path,
            "workspaceState": "empty",
        ])
    }

    func runTerminalRestartResumeFlow() throws {
        try waitForElement(identifier: "task-terminal-workspace", timeout: 10)
        try waitForElement(identifier: "terminal-pane-surface-codex-resume", timeout: 5)
        try waitForElement(identifier: "terminal-pane-surface-tmux-review", timeout: 5)

        try press(identifier: "terminal-pane-surface-tmux-review")
        try waitForResumeRequest(
            surfaceID: "surface-tmux-review",
            expectedCommand: "tmux attach -t task_task-resume-codex",
            timeout: 5
        )

        try finishFlow([
            "initialSelectedSurfaceId": "surface-codex-resume",
            "confirmedSurfaceId": "surface-tmux-review",
            "confirmedResumeCommand": "tmux attach -t task_task-resume-codex",
            "resumeRequestArtifact": artifactDirectory.appendingPathComponent("resume-request.json").path,
        ])
    }

}
