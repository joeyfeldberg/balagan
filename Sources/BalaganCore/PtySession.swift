import Darwin
import Foundation

public struct PtyCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct PtyWindowSize: Equatable, Sendable {
    public var columns: UInt16
    public var rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }
}

public struct PtyRunResult: Equatable, Sendable {
    public var output: Data
    public var exitStatus: Int32

    public var outputString: String {
        String(decoding: output, as: UTF8.self)
    }

    public init(output: Data, exitStatus: Int32) {
        self.output = output
        self.exitStatus = exitStatus
    }
}

public enum PtySessionError: Error, Equatable, Sendable {
    case openFailed(errno: Int32)
    case grantFailed(errno: Int32)
    case unlockFailed(errno: Int32)
    case missingSlaveName
    case forkFailed(errno: Int32)
    case spawnAttributeFailed(errno: Int32)
    case spawnFileActionFailed(errno: Int32)
    case spawnFailed(errno: Int32)
    case setsidFailed(errno: Int32)
    case openSlaveFailed(errno: Int32)
    case dupFailed(errno: Int32)
    case chdirFailed(path: String, errno: Int32)
    case execFailed(executable: String, errno: Int32)
    case setWindowSizeFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case waitFailed(errno: Int32)
}

public final class PtySession: @unchecked Sendable {
    private let masterFD: Int32
    private let childPID: pid_t
    private let slaveName: String
    private var hasWaited = false

    public static func spawn(
        _ command: PtyCommand,
        windowSize: PtyWindowSize = PtyWindowSize(columns: 120, rows: 40)
    ) throws -> PtySession {
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else {
            throw PtySessionError.openFailed(errno: errno)
        }

        do {
            guard grantpt(masterFD) == 0 else {
                throw PtySessionError.grantFailed(errno: errno)
            }

            guard unlockpt(masterFD) == 0 else {
                throw PtySessionError.unlockFailed(errno: errno)
            }

            guard let slaveNamePointer = ptsname(masterFD) else {
                throw PtySessionError.missingSlaveName
            }
            let slaveName = String(cString: slaveNamePointer)

            try setWindowSize(windowSize, slaveName: slaveName)

            let pid = try spawnChild(command: command, slaveName: slaveName, masterFD: masterFD, windowSize: windowSize)

            return PtySession(masterFD: masterFD, childPID: pid, slaveName: slaveName)
        } catch {
            close(masterFD)
            throw error
        }
    }

    private init(masterFD: Int32, childPID: pid_t, slaveName: String) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.slaveName = slaveName
    }

    deinit {
        close(masterFD)
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            var remaining = buffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(masterFD, baseAddress.advanced(by: offset), remaining)
                if written < 0 {
                    throw PtySessionError.writeFailed(errno: errno)
                }
                remaining -= written
                offset += written
            }
        }
    }

    public func write(_ string: String) throws {
        try write(Data(string.utf8))
    }

    public func readAvailable(maxBytes: Int = 4096) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = Darwin.read(masterFD, &buffer, maxBytes)
        if count > 0 {
            return Data(buffer.prefix(count))
        }
        if count == 0 {
            return Data()
        }
        if errno == EIO {
            return Data()
        }
        throw PtySessionError.readFailed(errno: errno)
    }

    public func setWindowSize(_ size: PtyWindowSize) throws {
        try Self.setWindowSize(size, slaveName: slaveName)
    }

    public func waitForExit() throws -> Int32 {
        guard !hasWaited else {
            return 0
        }

        var status: Int32 = 0
        while true {
            let result = waitpid(childPID, &status, 0)
            if result == childPID {
                hasWaited = true
                if waitStatusExited(status) {
                    return waitStatusExitCode(status)
                }
                if waitStatusSignaled(status) {
                    return 128 + waitStatusSignal(status)
                }
                return status
            }
            if result == -1, errno == EINTR {
                continue
            }
            throw PtySessionError.waitFailed(errno: errno)
        }
    }

    public static func run(
        _ command: PtyCommand,
        input: Data = Data(),
        windowSize: PtyWindowSize = PtyWindowSize(columns: 120, rows: 40),
        readChunkSize: Int = 4096
    ) throws -> PtyRunResult {
        let session = try spawn(command, windowSize: windowSize)
        if !input.isEmpty {
            try session.write(input)
        }

        var output = Data()
        while true {
            let chunk = try session.readAvailable(maxBytes: readChunkSize)
            if chunk.isEmpty {
                break
            }
            output.append(chunk)
        }

        let exitStatus = try session.waitForExit()
        return PtyRunResult(output: output, exitStatus: exitStatus)
    }

    private static func setWindowSize(_ size: PtyWindowSize, fd: Int32) throws {
        var windowSize = winsize(
            ws_row: size.rows,
            ws_col: size.columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        if ioctl(fd, TIOCSWINSZ, &windowSize) == -1 {
            throw PtySessionError.setWindowSizeFailed(errno: errno)
        }
    }

    private static func setWindowSize(_ size: PtyWindowSize, slaveName: String) throws {
        let slaveFD = slaveName.withCString { slaveNamePointer in
            Darwin.open(slaveNamePointer, O_RDWR | O_NOCTTY)
        }
        guard slaveFD >= 0 else {
            throw PtySessionError.openSlaveFailed(errno: errno)
        }
        defer { close(slaveFD) }

        try setWindowSize(size, fd: slaveFD)
    }
}

private func spawnChild(
    command: PtyCommand,
    slaveName: String,
    masterFD: Int32,
    windowSize: PtyWindowSize
) throws -> pid_t {
    let launchCommand = command.withPtyLaunchPrelude(windowSize: windowSize)
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?

    var result = posix_spawn_file_actions_init(&actions)
    guard result == 0 else {
        throw PtySessionError.spawnFileActionFailed(errno: result)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }

    result = posix_spawnattr_init(&attributes)
    guard result == 0 else {
        throw PtySessionError.spawnAttributeFailed(errno: result)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    try configureSpawnAttributes(&attributes)
    try configureSpawnFileActions(&actions, slaveName: slaveName, masterFD: masterFD)

    var argv = makeSpawnArgv(launchCommand)
    defer { freeCStrings(argv) }

    var envp = makeSpawnEnvp(launchCommand)
    defer { freeCStrings(envp) }

    var pid: pid_t = 0
    result = launchCommand.executable.withCString { executablePointer in
        posix_spawn(&pid, executablePointer, &actions, &attributes, &argv, &envp)
    }
    guard result == 0 else {
        throw PtySessionError.spawnFailed(errno: result)
    }

    return pid
}

private func configureSpawnAttributes(_ attributes: inout posix_spawnattr_t?) throws {
    let result = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    guard result == 0 else {
        throw PtySessionError.spawnAttributeFailed(errno: result)
    }
}

private func configureSpawnFileActions(
    _ actions: inout posix_spawn_file_actions_t?,
    slaveName: String,
    masterFD: Int32
) throws {
    var result = slaveName.withCString { slaveNamePointer in
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slaveNamePointer, O_RDWR, 0)
    }
    guard result == 0 else {
        throw PtySessionError.spawnFileActionFailed(errno: result)
    }

    result = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
    guard result == 0 else {
        throw PtySessionError.spawnFileActionFailed(errno: result)
    }

    result = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
    guard result == 0 else {
        throw PtySessionError.spawnFileActionFailed(errno: result)
    }

    result = posix_spawn_file_actions_addclose(&actions, masterFD)
    guard result == 0 else {
        throw PtySessionError.spawnFileActionFailed(errno: result)
    }
}

private func makeSpawnArgv(_ command: PtyCommand) -> [UnsafeMutablePointer<CChar>?] {
    let argvStorage = [command.executable] + command.arguments
    var argv = argvStorage.map { strdup($0) }
    argv.append(nil)
    return argv
}

private func makeSpawnEnvp(_ command: PtyCommand) -> [UnsafeMutablePointer<CChar>?] {
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in command.environment {
        environment[key] = value
    }
    let envStorage = environment.map { "\($0.key)=\($0.value)" }
    var envp = envStorage.map { strdup($0) }
    envp.append(nil)
    return envp
}

private func freeCStrings(_ pointers: [UnsafeMutablePointer<CChar>?]) {
    for pointer in pointers where pointer != nil {
        free(pointer)
    }
}

private extension PtyCommand {
    func withPtyLaunchPrelude(windowSize: PtyWindowSize) -> PtyCommand {
        return PtyCommand(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/bin/stty rows \"$1\" cols \"$2\" 2>/dev/null || true; shift 2; if [ -n \"$1\" ]; then cd \"$1\" || exit 125; fi; shift; exec \"$@\"",
                "balagan-pty-launch",
                String(windowSize.rows),
                String(windowSize.columns),
                workingDirectory ?? "",
                executable,
            ] + arguments,
            environment: environment
        )
    }
}

private func waitStatusExited(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}

private func waitStatusExitCode(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func waitStatusSignaled(_ status: Int32) -> Bool {
    let waitStatus = status & 0x7f
    return waitStatus != 0x7f && waitStatus != 0
}

private func waitStatusSignal(_ status: Int32) -> Int32 {
    status & 0x7f
}
