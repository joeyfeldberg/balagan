public protocol TerminalProcessRunning: Sendable {
    func run(_ command: PtyCommand, windowSize: PtyWindowSize) throws -> PtyRunResult
}

public struct LivePtyProcessRunner: TerminalProcessRunning {
    public init() {}

    public func run(_ command: PtyCommand, windowSize: PtyWindowSize) throws -> PtyRunResult {
        try PtySession.run(command, windowSize: windowSize)
    }
}
