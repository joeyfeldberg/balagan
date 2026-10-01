import Darwin
import Foundation
import BalaganCore

extension BalaganApplication {
    func startSessionReportServer(options: LaunchOptions, viewModel: BoardViewModel) {
        do {
            let server = try SessionReportServer(socketPath: options.sessionReportSocketPath) { [weak self, weak viewModel] event in
                DispatchQueue.main.async { [weak self, weak viewModel] in
                    guard let self, let viewModel else {
                        return
                    }
                    let result = viewModel.applyReportedSessionCapture(event)
                    self.persistBoardState()
                    self.writeSessionReportArtifact(event: event, result: result, options: options)
                    self.writeReadyArtifactIfPossible(options: options, viewModel: viewModel)
                }
            }
            sessionReportServer = server
            server.start()
            writeSessionSocketArtifact(options: options)
        } catch {
            guard let artifactDirectory = options.artifactDirectory else {
                return
            }
            let message = "Failed to start session report socket: \(error)\n"
            try? message.write(
                to: artifactDirectory.appendingPathComponent("session-report-socket-error.log"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func writeSessionSocketArtifact(options: LaunchOptions) {
        guard let artifactDirectory = options.artifactDirectory else {
            return
        }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "endpoint": "unix-domain-socket-jsonl",
            "socketPath": options.sessionReportSocketPath,
        ]
        ArtifactWriter.writeJSON(
            payload,
            to: artifactDirectory,
            as: "session-report-socket.json",
            errorLog: "session-report-socket-error.log",
            failureMessage: "Failed to write session report socket artifact"
        )
    }

    private func writeSessionReportArtifact(
        event: SessionReportEvent,
        result: SessionReportApplyResult,
        options: LaunchOptions
    ) {
        guard let artifactDirectory = options.artifactDirectory else {
            return
        }

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "event": event.event.rawValue,
            "taskID": event.taskID,
            "workspaceID": event.workspaceID,
            "surfaceID": event.surfaceID,
            "agentName": event.agentName.map { $0 as Any } ?? NSNull(),
            "sessionID": event.sessionID.map { $0 as Any } ?? NSNull(),
            "status": result.status,
            "message": result.message,
            "resumeCommand": result.resumeCommand.map { $0 as Any } ?? NSNull(),
        ]

        ArtifactWriter.writeJSON(
            payload,
            to: artifactDirectory,
            as: "session-report-last.json",
            errorLog: "session-report-error.log",
            failureMessage: "Failed to write session report artifact"
        )
    }
}

struct SessionReportApplyResult {
    var status: String
    var message: String
    var resumeCommand: String?
}

final class SessionReportServer {
    private let socketPath: String
    private let onEvent: (SessionReportEvent) -> Void
    private let queue = DispatchQueue.main
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(socketPath: String, onEvent: @escaping (SessionReportEvent) -> Void) throws {
        guard socketPath.utf8.count < UnixSocketHelpers.maxPathLength else {
            throw SessionReportServerError.socketPathTooLong(socketPath)
        }
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    func start() {
        startOnQueue()
    }

    func stop() {
        if let source {
            source.cancel()
            self.source = nil
            listenFD = -1
        } else if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func startOnQueue() {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            unlink(socketPath)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw SessionReportServerError.socketFailed(errno)
            }
            listenFD = fd

            var flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                flags |= O_NONBLOCK
                _ = fcntl(fd, F_SETFL, flags)
            }

            let address = UnixSocketHelpers.makeAddress(path: socketPath)
            guard UnixSocketHelpers.bind(fd, to: address) == 0 else {
                throw SessionReportServerError.bindFailed(errno)
            }

            guard listen(fd, 8) == 0 else {
                throw SessionReportServerError.listenFailed(errno)
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptAvailableConnections()
            }
            source.setCancelHandler { [fd] in
                Darwin.close(fd)
            }
            self.source = source
            source.resume()
        } catch {
            if listenFD >= 0 {
                Darwin.close(listenFD)
                listenFD = -1
            }
            writeError("session report socket start failed: \(error)")
        }
    }

    private func acceptAvailableConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    writeError("session report accept failed: errno \(errno)")
                }
                return
            }
            var flags = fcntl(clientFD, F_GETFL, 0)
            if flags >= 0 {
                flags &= ~O_NONBLOCK
                _ = fcntl(clientFD, F_SETFL, flags)
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            writeError("session report read failed: errno \(errno)")
            break
        }
        Darwin.close(clientFD)

        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            do {
                onEvent(try SessionReportEventParser.parseLine(String(line)))
            } catch {
                writeError("session report parse failed: \(error)")
            }
        }
    }

    private func writeError(_ message: String) {
        let errorPath = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            .appendingPathComponent("session-report-socket-error.log")
        let line = message + "\n"
        if FileManager.default.fileExists(atPath: errorPath.path),
           let handle = try? FileHandle(forWritingTo: errorPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: errorPath, atomically: true, encoding: .utf8)
        }
    }
}

private enum SessionReportServerError: Error, CustomStringConvertible {
    case socketPathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var description: String {
        switch self {
        case .socketPathTooLong(let path):
            return "socket path is too long for sockaddr_un: \(path)"
        case .socketFailed(let value):
            return "socket(AF_UNIX) failed with errno \(value)"
        case .bindFailed(let value):
            return "bind(AF_UNIX) failed with errno \(value)"
        case .listenFailed(let value):
            return "listen(AF_UNIX) failed with errno \(value)"
        }
    }
}
