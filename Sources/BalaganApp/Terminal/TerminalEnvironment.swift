import Foundation
import SwiftUI
import BalaganCore

struct TerminalRuntimeOptions: Equatable {
    var selection: TerminalBackendSelection
    var libGhosttyPath: String?
    var sessionReportSocketPath: String
    var processPreference: ResumeLaunchProcessPreference
    /// The `balagan-agent` wrapper path, so a resume launch can be run through it (installing the
    /// Claude session/lifecycle hooks) instead of executing `claude --resume` bare.
    var agentWrapperPath: String?

    init(options: LaunchOptions) {
        self.selection = TerminalBackendSelector.select(
            uiTestMode: options.uiTestMode,
            disableRealProcesses: options.disableRealProcesses,
            explicitLibGhosttyPath: options.libGhosttyPath
        )
        self.libGhosttyPath = options.libGhosttyPath ?? selection.libGhostty.path
        self.sessionReportSocketPath = options.sessionReportSocketPath
        self.processPreference = selection.kind == .libghostty ? .allowProcessLaunch : .restoreOnly
        self.agentWrapperPath = options.agentWrapperPath
    }

    static let fixture = TerminalRuntimeOptions(
        selection: TerminalBackendSelection(
            kind: .fixture,
            reason: "default fixture runtime",
            libGhostty: LibGhosttyRuntimeStatus(isAvailable: false, source: .unavailable)
        ),
        libGhosttyPath: nil,
        sessionReportSocketPath: "",
        processPreference: .restoreOnly,
        agentWrapperPath: nil
    )

    private init(
        selection: TerminalBackendSelection,
        libGhosttyPath: String?,
        sessionReportSocketPath: String,
        processPreference: ResumeLaunchProcessPreference,
        agentWrapperPath: String?
    ) {
        self.selection = selection
        self.libGhosttyPath = libGhosttyPath
        self.sessionReportSocketPath = sessionReportSocketPath
        self.processPreference = processPreference
        self.agentWrapperPath = agentWrapperPath
    }
}

private struct ArtifactDirectoryKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

private struct TerminalRuntimeKey: EnvironmentKey {
    static let defaultValue = TerminalRuntimeOptions.fixture
}

private struct TerminalAppearanceKey: EnvironmentKey {
    static let defaultValue = TerminalAppearanceSettings()
}

private struct BalaganUIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = CGFloat(UIAppearanceSettings.defaultScale)
}

extension EnvironmentValues {
    var artifactDirectory: URL? {
        get { self[ArtifactDirectoryKey.self] }
        set { self[ArtifactDirectoryKey.self] = newValue }
    }

    var terminalRuntime: TerminalRuntimeOptions {
        get { self[TerminalRuntimeKey.self] }
        set { self[TerminalRuntimeKey.self] = newValue }
    }

    var terminalAppearance: TerminalAppearanceSettings {
        get { self[TerminalAppearanceKey.self] }
        set { self[TerminalAppearanceKey.self] = newValue }
    }

    var balaganUIScale: CGFloat {
        get { self[BalaganUIScaleKey.self] }
        set { self[BalaganUIScaleKey.self] = newValue }
    }
}

private struct BalaganUIScaleModifier: ViewModifier {
    let scale: Double

    func body(content: Content) -> some View {
        let boundedScale = UIAppearanceSettings.clampedScale(scale)
        content
            .environment(\.balaganUIScale, CGFloat(boundedScale))
            .dynamicTypeSize(dynamicTypeSize(for: boundedScale))
    }

    private func dynamicTypeSize(for scale: Double) -> DynamicTypeSize {
        switch scale {
        case ..<0.9:
            return .small
        case ..<1.1:
            return .medium
        case ..<1.2:
            return .large
        case ..<1.3:
            return .xLarge
        case ..<1.4:
            return .xxLarge
        default:
            return .xxxLarge
        }
    }
}

extension View {
    func balaganUIScale(_ scale: Double) -> some View {
        modifier(BalaganUIScaleModifier(scale: UIAppearanceSettings.clampedScale(scale)))
    }
}
