import Foundation

public enum TerminalBackendKind: String, Codable, Equatable, Sendable {
    case fixture
    case libghostty
    case unavailable
}

public struct TerminalBackendSelection: Codable, Equatable, Sendable {
    public var kind: TerminalBackendKind
    public var reason: String
    public var libGhostty: LibGhosttyRuntimeStatus

    public init(kind: TerminalBackendKind, reason: String, libGhostty: LibGhosttyRuntimeStatus) {
        self.kind = kind
        self.reason = reason
        self.libGhostty = libGhostty
    }
}

public enum TerminalBackendSelector {
    public static func select(
        uiTestMode: Bool,
        disableRealProcesses: Bool,
        explicitLibGhosttyPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalBackendSelection {
        if uiTestMode || disableRealProcesses {
            return TerminalBackendSelection(
                kind: .fixture,
                reason: "real process launch disabled",
                libGhostty: LibGhosttyRuntimeStatus(isAvailable: false, source: .unavailable)
            )
        }

        let status = LibGhosttyRuntimeProbe.probe(
            explicitPath: explicitLibGhosttyPath,
            environment: environment
        )

        if status.isAvailable {
            return TerminalBackendSelection(
                kind: .libghostty,
                reason: "libghostty runtime available",
                libGhostty: status
            )
        }

        return TerminalBackendSelection(
            kind: .unavailable,
            reason: "libghostty runtime unavailable",
            libGhostty: status
        )
    }
}
