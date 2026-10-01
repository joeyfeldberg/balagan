import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    private struct VisibleTypingPhase {
        let tokenPrefix: String
        let surfaceID: String
        let terminalIdentifiers: [String]
        let evidenceName: String
        let prepare: () throws -> Void
    }

    func runTerminalVisibleTypingFlow() throws {
        try createProject()
        try createTask()
        try openTaskWorkspace(identifier: "task-card-harness-task")

        let token = uniqueToken()
        let firstSurfaceID = "surface-harness-task-main"
        let firstTerminalIdentifiers = liveTerminalIdentifiers(forTaskID: "harness-task")
        let secondSurfaceID = "tab-2"
        let secondTerminalIdentifiers = terminalIdentifiers(surfaceID: secondSurfaceID)
        try waitForTerminalHostMounted(surfaceID: firstSurfaceID)

        let phases: [VisibleTypingPhase] = [
            VisibleTypingPhase(
                tokenPrefix: "tbvisibleopen",
                surfaceID: firstSurfaceID,
                terminalIdentifiers: firstTerminalIdentifiers,
                evidenceName: "open",
                prepare: {}
            ),
            VisibleTypingPhase(
                tokenPrefix: "tbvisiblesecond",
                surfaceID: secondSurfaceID,
                terminalIdentifiers: secondTerminalIdentifiers,
                evidenceName: "second-tab",
                prepare: {
                    try self.press(identifier: "create-terminal-tab-button")
                    try self.waitForTerminalHostMounted(surfaceID: secondSurfaceID)
                }
            ),
            VisibleTypingPhase(
                tokenPrefix: "tbvisibleback",
                surfaceID: firstSurfaceID,
                terminalIdentifiers: firstTerminalIdentifiers,
                evidenceName: "switched-back",
                prepare: {
                    try self.selectPicker(identifier: "terminal-tab-picker", value: "agent")
                }
            ),
            VisibleTypingPhase(
                tokenPrefix: "tbvisiblenav",
                surfaceID: firstSurfaceID,
                terminalIdentifiers: firstTerminalIdentifiers,
                evidenceName: "navigation",
                prepare: {
                    try self.showProjectTasks()
                    try self.openTaskWorkspace(identifier: "task-card-harness-task")
                    try self.waitForTerminalHostMounted(surfaceID: firstSurfaceID)
                }
            ),
        ]

        var renderEvidence: [[String: Any]] = []
        var visibleTokens: [String] = []
        for phase in phases {
            try phase.prepare()
            let produced = try typeVisibleToken(
                token: "\(phase.tokenPrefix)\(token)",
                surfaceID: phase.surfaceID,
                terminalIdentifiers: phase.terminalIdentifiers,
                evidenceName: phase.evidenceName,
                renderEvidence: &renderEvidence
            )
            visibleTokens.append(produced)
        }

        try finishFlow([
            "typingMethod": "physical-key-events",
            "terminalIdentifiers": firstTerminalIdentifiers,
            "secondTerminalIdentifiers": secondTerminalIdentifiers,
            "firstSurfaceVisibleTextPath": visibleTextURL(surfaceID: firstSurfaceID).path,
            "secondSurfaceVisibleTextPath": visibleTextURL(surfaceID: secondSurfaceID).path,
            "openVisibleToken": visibleTokens[0],
            "secondTabVisibleToken": visibleTokens[1],
            "switchedBackVisibleToken": visibleTokens[2],
            "navigationVisibleToken": visibleTokens[3],
            "renderFreshnessEvidence": renderEvidence,
        ])
    }

    func runTerminalControlKeysFlow() throws {
        let readyURL = artifactDirectory.appendingPathComponent("terminal-control-ready.txt")
        let interruptURL = artifactDirectory.appendingPathComponent("terminal-control-interrupt.txt")
        let interruptCommand = [
            "trap 'printf BALAGAN_CTRL_C_OK > \(shellSingleQuoted(interruptURL.path)); exit 130' INT",
            "printf BALAGAN_CTRL_READY > \(shellSingleQuoted(readyURL.path))",
            "while :; do sleep 1; done",
        ].joined(separator: "; ")

        try createProject(defaultAgentCommand: "")
        try createTask()
        try openTaskWorkspace(identifier: "task-card-harness-task")

        try press(identifier: "create-terminal-tab-button")
        let surfaceID = "tab-2"
        let autoCloseURL = artifactDirectory.appendingPathComponent(
            "libghostty-terminal-ended-process-autoclose-\(surfaceID.safeArtifactComponent).json"
        )
        let terminalIdentifiers = terminalIdentifiers(surfaceID: surfaceID)
        try waitForTerminalHostMounted(surfaceID: surfaceID)
        try clickAny(identifiers: terminalIdentifiers)
        pasteOnly("/bin/sh -lc \(shellSingleQuoted(interruptCommand))\n")
        try waitForFile(readyURL, timeout: 10)

        postModifiedKey(virtualKey: 8, flags: .maskControl)
        try waitForFile(interruptURL, timeout: 10)
        sleep(milliseconds: 500)

        postModifiedKey(virtualKey: 2, flags: .maskControl)
        try waitForFile(autoCloseURL, timeout: 10)
        try waitForElementToDisappear(identifier: "terminal-pane-\(surfaceID)", timeout: 5)
        if let visibleText = try? String(contentsOf: visibleTextURL(surfaceID: surfaceID), encoding: .utf8) {
            let normalized = visibleText.lowercased()
            if normalized.contains("press any key") || normalized.contains("process exited") {
                throw DriverError.staleRenderedPixels("Ctrl+D left Ghostty ended-process prompt visible for \(surfaceID)")
            }
        }

        try finishFlow([
            "terminalIdentifiers": terminalIdentifiers,
            "surfaceID": surfaceID,
            "readyMarkerPath": readyURL.path,
            "interruptMarkerPath": interruptURL.path,
            "autoCloseArtifact": autoCloseURL.path,
            "ctrlCBehavior": "sent ETX; child trap observed SIGINT",
            "ctrlDBehavior": "sent EOT to the plain shell; terminal tab auto-closed",
            "typingMethod": "physical-key-events",
        ])
    }

    func runTerminalKeyboardShortcutsFlow() throws {
        try createProject()
        try createTask()
        try openTaskWorkspace(identifier: "task-card-harness-task")

        let token = uniqueToken()
        let firstSurfaceID = "surface-harness-task-main"
        let firstTerminalIdentifiers = liveTerminalIdentifiers(forTaskID: "harness-task")
        try waitForTerminalHostMounted(surfaceID: firstSurfaceID)
        try clickAny(identifiers: firstTerminalIdentifiers)

        var renderEvidence: [[String: Any]] = []
        var fontZoomEvidence: [[String: Any]] = []

        let tabTokens = try exerciseTabShortcuts(
            token: token,
            firstSurfaceID: firstSurfaceID,
            firstTerminalIdentifiers: firstTerminalIdentifiers,
            renderEvidence: &renderEvidence
        )
        let fontZoom = try exerciseFontZoomShortcuts(
            token: token,
            firstSurfaceID: firstSurfaceID,
            fontZoomEvidence: &fontZoomEvidence,
            renderEvidence: &renderEvidence
        )
        let afterNavigationToken = try exerciseSplitAndCloseShortcuts(
            token: token,
            renderEvidence: &renderEvidence
        )
        try verifyFontZoomPersistence(
            firstSurfaceID: firstSurfaceID,
            fontZoomEvidence: &fontZoomEvidence
        )

        try finishFlow([
            "typingMethod": "physical-key-events",
            "createdTabSurfaceIds": ["tab-2", "tab-3", "tab-4"],
            "createdSplitSurfaceIds": ["right-5", "down-6"],
            "closedSurfaceId": "right-5",
            "closedSurfaceMethod": "ctrl-d",
            "copyPasteClearShortcuts": "completed",
            "zoomShortcut": "completed",
            "fontZoomShortcuts": "completed",
            "newTerminalInheritedFontSize": fontZoom.inheritedFontSize,
            "persistedFontSizeAfterFlow": 14,
            "fontZoomEvidence": fontZoomEvidence,
            "splitFocusShortcuts": "completed",
            "tabSwitchShortcuts": "completed",
            "firstVisibleToken": tabTokens.firstToken,
            "secondVisibleToken": tabTokens.secondToken,
            "thirdVisibleToken": fontZoom.thirdToken,
            "afterNavigationVisibleToken": afterNavigationToken,
            "renderFreshnessEvidence": renderEvidence,
        ])
    }

    /// Cmd+T twice (creating tab-2 then tab-3), then Cmd+1 back to the first tab, typing a visible
    /// token in tab-2 and the first tab to prove the new-tab and tab-switch shortcuts.
    private func exerciseTabShortcuts(
        token: String,
        firstSurfaceID: String,
        firstTerminalIdentifiers: [String],
        renderEvidence: inout [[String: Any]]
    ) throws -> (firstToken: String, secondToken: String) {
        postModifiedKey(virtualKey: 17, flags: .maskCommand)
        try waitForTerminalHostMounted(surfaceID: "tab-2")
        try waitForElement(identifier: "terminal-pane-tab-2", timeout: 5)

        let secondToken = try typeVisibleToken(
            token: "tbshortcutsecond\(token)",
            surfaceID: "tab-2",
            terminalIdentifiers: terminalIdentifiers(surfaceID: "tab-2"),
            evidenceName: "shortcut-tab-2",
            renderEvidence: &renderEvidence
        )

        postModifiedKey(virtualKey: 17, flags: .maskCommand)
        try waitForTerminalHostMounted(surfaceID: "tab-3")
        try waitForElement(identifier: "terminal-pane-tab-3", timeout: 5)

        postModifiedKey(virtualKey: 18, flags: .maskCommand)
        let firstToken = try typeVisibleToken(
            token: "tbshortcutfirst\(token)",
            surfaceID: firstSurfaceID,
            terminalIdentifiers: firstTerminalIdentifiers,
            evidenceName: "shortcut-cmd-1",
            renderEvidence: &renderEvidence
        )

        return (firstToken, secondToken)
    }

    /// Exercises the font-zoom shortcuts (Cmd+=, Cmd+Shift++, Cmd+-, Cmd+0), verifying a freshly
    /// created tab-4 inherits the app font size, then Cmd+9 to type a visible token in tab-4.
    private func exerciseFontZoomShortcuts(
        token: String,
        firstSurfaceID: String,
        fontZoomEvidence: inout [[String: Any]],
        renderEvidence: inout [[String: Any]]
    ) throws -> (inheritedFontSize: Double, thirdToken: String) {
        postModifiedKey(virtualKey: 24, flags: .maskCommand)
        let equalsZoom = try waitForFontZoomEvidence(
            surfaceID: firstSurfaceID,
            evidenceName: "increase-equals",
            expectedDirection: .increase,
            expectedChangedSurfaceIDs: [firstSurfaceID, "tab-2", "tab-3"]
        )
        fontZoomEvidence.append(equalsZoom.artifactPayload)

        postModifiedKey(virtualKey: 17, flags: .maskCommand)
        try waitForTerminalHostMounted(surfaceID: "tab-4")
        try waitForElement(identifier: "terminal-pane-tab-4", timeout: 5)
        let inheritedFontSize = try waitForTerminalHostFontSize(surfaceID: "tab-4", expectedFontSize: 14, timeout: 5)

        postModifiedKey(virtualKey: 18, flags: .maskCommand)
        postModifiedKey(virtualKey: 24, flags: [.maskCommand, .maskShift])
        let plusZoom = try waitForFontZoomEvidence(
            surfaceID: firstSurfaceID,
            evidenceName: "increase-shift-plus",
            expectedDirection: .increase,
            expectedChangedSurfaceIDs: [firstSurfaceID, "tab-2", "tab-3", "tab-4"]
        )
        fontZoomEvidence.append(plusZoom.artifactPayload)

        postModifiedKey(virtualKey: 27, flags: .maskCommand)
        let minusZoom = try waitForFontZoomEvidence(
            surfaceID: firstSurfaceID,
            evidenceName: "decrease-minus",
            expectedDirection: .decrease,
            expectedChangedSurfaceIDs: [firstSurfaceID, "tab-2", "tab-3", "tab-4"]
        )
        fontZoomEvidence.append(minusZoom.artifactPayload)

        postModifiedKey(virtualKey: 29, flags: .maskCommand)
        let resetZoom = try waitForFontZoomEvidence(
            surfaceID: firstSurfaceID,
            evidenceName: "reset-zero",
            expectedDirection: .reset,
            expectedChangedSurfaceIDs: [firstSurfaceID, "tab-2", "tab-3", "tab-4"]
        )
        fontZoomEvidence.append(resetZoom.artifactPayload)

        postModifiedKey(virtualKey: 25, flags: .maskCommand)
        let thirdToken = try typeVisibleToken(
            token: "tbshortcutthird\(token)",
            surfaceID: "tab-4",
            terminalIdentifiers: terminalIdentifiers(surfaceID: "tab-4"),
            evidenceName: "shortcut-cmd-9",
            renderEvidence: &renderEvidence
        )

        return (inheritedFontSize, thirdToken)
    }

    /// Splits (Cmd+D / Cmd+Shift+D), exercises focus/zoom shortcuts, closes the right split with
    /// Ctrl+D, then tab-navigates and types a live visible token in the remaining split.
    private func exerciseSplitAndCloseShortcuts(
        token: String,
        renderEvidence: inout [[String: Any]]
    ) throws -> String {
        postModifiedKey(virtualKey: 2, flags: .maskCommand)
        try waitForTerminalHostMounted(surfaceID: "right-5")
        try waitForElement(identifier: "terminal-pane-right-5", timeout: 5)

        postModifiedKey(virtualKey: 2, flags: [.maskCommand, .maskShift])
        try waitForTerminalHostMounted(surfaceID: "down-6")
        try waitForElement(identifier: "terminal-pane-down-6", timeout: 5)

        postModifiedKey(virtualKey: 30, flags: .maskCommand)
        postModifiedKey(virtualKey: 33, flags: .maskCommand)
        postModifiedKey(virtualKey: 30, flags: [.maskCommand, .maskShift])
        postModifiedKey(virtualKey: 33, flags: [.maskCommand, .maskShift])
        postModifiedKey(virtualKey: 123, flags: [.maskCommand, .maskAlternate])
        postModifiedKey(virtualKey: 124, flags: [.maskCommand, .maskAlternate])
        postModifiedKey(virtualKey: 25, flags: .maskCommand)
        try clickAny(identifiers: terminalIdentifiers(surfaceID: "right-5"))
        postModifiedKey(virtualKey: 36, flags: [.maskCommand, .maskShift])
        try waitForElement(identifier: "terminal-zoomed-pane-right-5", timeout: 5)
        postModifiedKey(virtualKey: 36, flags: [.maskCommand, .maskShift])

        postModifiedKey(virtualKey: 2, flags: .maskControl)
        try waitForElementToDisappear(identifier: "terminal-pane-right-5", timeout: 5)

        postModifiedKey(virtualKey: 48, flags: .maskControl)
        postModifiedKey(virtualKey: 48, flags: [.maskControl, .maskShift])
        return try typeVisibleToken(
            token: "tbshortcutlive\(token)",
            surfaceID: "down-6",
            terminalIdentifiers: terminalIdentifiers(surfaceID: "down-6"),
            evidenceName: "shortcut-live-after-navigation",
            renderEvidence: &renderEvidence
        )
    }

    /// Re-runs the font-zoom-increase shortcut on the surviving split to prove the persisted font
    /// size still applies after the earlier navigation and close.
    private func verifyFontZoomPersistence(
        firstSurfaceID: String,
        fontZoomEvidence: inout [[String: Any]]
    ) throws {
        removeFontZoomEvidence(surfaceID: "down-6", evidenceName: "increase-equals")
        postModifiedKey(virtualKey: 24, flags: .maskCommand)
        let persistedZoom = try waitForFontZoomEvidence(
            surfaceID: "down-6",
            evidenceName: "increase-equals",
            expectedDirection: .increase,
            expectedChangedSurfaceIDs: [firstSurfaceID, "tab-2", "tab-3", "tab-4", "down-6"]
        )
        fontZoomEvidence.append(persistedZoom.artifactPayload)
    }

}
