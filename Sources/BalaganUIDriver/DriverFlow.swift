import Foundation

enum DriverFlow: CaseIterable {
    case nativeFlow
    case dailyDriver
    case terminalInput
    case terminalManualInput
    case terminalVisibleTyping
    case terminalControlKeys
    case terminalNavigation
    case terminalKeyboardShortcuts
    case terminalRestartResume
    case terminalReloadPrompt
    case terminalCloseOpenPrompt
    case terminalEndedAutoclose
    case settings

    /// The full set of contract strings for a flow. Every value is a literal so it stays
    /// byte-identical in the binary — note `.nativeFlow`'s dump names deliberately use
    /// `ui-native-accessibility-*`, not `ui-native-flow-*`.
    private struct FlowDescriptor {
        let argument: String
        let name: String
        let driverArtifactName: String
        let errorArtifactName: String
        let lookupDumpName: String
        let finalDumpName: String
    }

    init(argument: String) throws {
        guard let match = DriverFlow.allCases.first(where: { $0.descriptor.argument == argument }) else {
            throw DriverError.invalidArguments("invalid --flow: \(argument)")
        }
        self = match
    }

    var name: String { descriptor.name }
    var driverArtifactName: String { descriptor.driverArtifactName }
    var errorArtifactName: String { descriptor.errorArtifactName }
    var lookupDumpName: String { descriptor.lookupDumpName }
    var finalDumpName: String { descriptor.finalDumpName }

    private var descriptor: FlowDescriptor {
        switch self {
        case .nativeFlow:
            return FlowDescriptor(
                argument: "native-flow",
                name: "native-accessibility-create-edit-status-tab",
                driverArtifactName: "ui-native-flow-driver.json",
                errorArtifactName: "ui-native-flow-driver-error.txt",
                lookupDumpName: "ui-native-accessibility-dump.txt",
                finalDumpName: "ui-native-accessibility-final.txt"
            )
        case .dailyDriver:
            return FlowDescriptor(
                argument: "daily-driver",
                name: "native-accessibility-daily-driver",
                driverArtifactName: "ui-daily-driver.json",
                errorArtifactName: "ui-daily-driver-error.txt",
                lookupDumpName: "ui-daily-driver-accessibility-dump.txt",
                finalDumpName: "ui-daily-driver-accessibility-final.txt"
            )
        case .terminalInput:
            return FlowDescriptor(
                argument: "terminal-input",
                name: "native-accessibility-terminal-input",
                driverArtifactName: "ui-terminal-input-driver.json",
                errorArtifactName: "ui-terminal-input-driver-error.txt",
                lookupDumpName: "ui-terminal-input-accessibility-dump.txt",
                finalDumpName: "ui-terminal-input-accessibility-final.txt"
            )
        case .terminalManualInput:
            return FlowDescriptor(
                argument: "terminal-manual-input",
                name: "native-accessibility-terminal-manual-input",
                driverArtifactName: "ui-terminal-manual-input-driver.json",
                errorArtifactName: "ui-terminal-manual-input-driver-error.txt",
                lookupDumpName: "ui-terminal-manual-input-accessibility-dump.txt",
                finalDumpName: "ui-terminal-manual-input-accessibility-final.txt"
            )
        case .terminalVisibleTyping:
            return FlowDescriptor(
                argument: "terminal-visible-typing",
                name: "native-accessibility-terminal-visible-typing",
                driverArtifactName: "ui-terminal-visible-typing-driver.json",
                errorArtifactName: "ui-terminal-visible-typing-driver-error.txt",
                lookupDumpName: "ui-terminal-visible-typing-accessibility-dump.txt",
                finalDumpName: "ui-terminal-visible-typing-accessibility-final.txt"
            )
        case .terminalControlKeys:
            return FlowDescriptor(
                argument: "terminal-control-keys",
                name: "native-accessibility-terminal-control-keys",
                driverArtifactName: "ui-terminal-control-keys-driver.json",
                errorArtifactName: "ui-terminal-control-keys-driver-error.txt",
                lookupDumpName: "ui-terminal-control-keys-accessibility-dump.txt",
                finalDumpName: "ui-terminal-control-keys-accessibility-final.txt"
            )
        case .terminalNavigation:
            return FlowDescriptor(
                argument: "terminal-navigation",
                name: "native-accessibility-terminal-navigation-persistence",
                driverArtifactName: "ui-terminal-navigation-driver.json",
                errorArtifactName: "ui-terminal-navigation-driver-error.txt",
                lookupDumpName: "ui-terminal-navigation-accessibility-dump.txt",
                finalDumpName: "ui-terminal-navigation-accessibility-final.txt"
            )
        case .terminalKeyboardShortcuts:
            return FlowDescriptor(
                argument: "terminal-keyboard-shortcuts",
                name: "native-accessibility-terminal-keyboard-shortcuts",
                driverArtifactName: "ui-terminal-keyboard-shortcuts-driver.json",
                errorArtifactName: "ui-terminal-keyboard-shortcuts-driver-error.txt",
                lookupDumpName: "ui-terminal-keyboard-shortcuts-accessibility-dump.txt",
                finalDumpName: "ui-terminal-keyboard-shortcuts-accessibility-final.txt"
            )
        case .terminalRestartResume:
            return FlowDescriptor(
                argument: "terminal-restart-resume",
                name: "native-accessibility-terminal-restart-resume",
                driverArtifactName: "ui-terminal-restart-resume-driver.json",
                errorArtifactName: "ui-terminal-restart-resume-driver-error.txt",
                lookupDumpName: "ui-terminal-restart-resume-accessibility-dump.txt",
                finalDumpName: "ui-terminal-restart-resume-accessibility-final.txt"
            )
        case .terminalReloadPrompt:
            return FlowDescriptor(
                argument: "terminal-reload-prompt",
                name: "native-accessibility-terminal-reload-prompt",
                driverArtifactName: "ui-terminal-reload-prompt-driver.json",
                errorArtifactName: "ui-terminal-reload-prompt-driver-error.txt",
                lookupDumpName: "ui-terminal-reload-prompt-accessibility-dump.txt",
                finalDumpName: "ui-terminal-reload-prompt-accessibility-final.txt"
            )
        case .terminalCloseOpenPrompt:
            return FlowDescriptor(
                argument: "terminal-close-open-prompt",
                name: "native-accessibility-terminal-close-open-prompt",
                driverArtifactName: "ui-terminal-close-open-prompt-driver.json",
                errorArtifactName: "ui-terminal-close-open-prompt-driver-error.txt",
                lookupDumpName: "ui-terminal-close-open-prompt-accessibility-dump.txt",
                finalDumpName: "ui-terminal-close-open-prompt-accessibility-final.txt"
            )
        case .terminalEndedAutoclose:
            return FlowDescriptor(
                argument: "terminal-ended-autoclose",
                name: "native-accessibility-terminal-ended-autoclose",
                driverArtifactName: "ui-terminal-ended-autoclose-driver.json",
                errorArtifactName: "ui-terminal-ended-autoclose-driver-error.txt",
                lookupDumpName: "ui-terminal-ended-autoclose-accessibility-dump.txt",
                finalDumpName: "ui-terminal-ended-autoclose-accessibility-final.txt"
            )
        case .settings:
            return FlowDescriptor(
                argument: "settings",
                name: "native-accessibility-settings",
                driverArtifactName: "ui-settings-driver.json",
                errorArtifactName: "ui-settings-driver-error.txt",
                lookupDumpName: "ui-settings-accessibility-dump.txt",
                finalDumpName: "ui-settings-accessibility-final.txt"
            )
        }
    }
}
