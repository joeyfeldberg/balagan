import ApplicationServices
import Darwin
import Foundation

final class NativeFlowDriver {
    let app: AXUIElement
    let artifactDirectory: URL
    let flow: DriverFlow

    init(pid: pid_t, artifactDirectory: URL, flow: DriverFlow) {
        self.app = AXUIElementCreateApplication(pid)
        self.artifactDirectory = artifactDirectory
        self.flow = flow
    }

    func run() throws {
        guard AXIsProcessTrusted() else {
            throw DriverError.accessibilityNotTrusted
        }

        try focusApplication()
        try waitForElement(identifier: "create-project-button", timeout: 10)

        switch flow {
        case .nativeFlow:
            try runNativeFlow()
        case .dailyDriver:
            try runDailyDriverFlow()
        case .terminalInput:
            try runTerminalInputFlow()
        case .terminalManualInput:
            try runTerminalManualInputFlow()
        case .terminalVisibleTyping:
            try runTerminalVisibleTypingFlow()
        case .terminalControlKeys:
            try runTerminalControlKeysFlow()
        case .terminalNavigation:
            try runTerminalNavigationFlow()
        case .terminalKeyboardShortcuts:
            try runTerminalKeyboardShortcutsFlow()
        case .terminalRestartResume:
            try runTerminalRestartResumeFlow()
        case .terminalReloadPrompt:
            try runTerminalReloadPromptFlow()
        case .terminalCloseOpenPrompt:
            try runTerminalCloseOpenPromptFlow()
        case .terminalEndedAutoclose:
            try runTerminalEndedAutocloseFlow()
        case .settings:
            try runSettingsFlow()
        }
    }
}
