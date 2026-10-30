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
    private var listener: UnixSocketListener!

    init(socketPath: String, onEvent: @escaping (SessionReportEvent) -> Void) throws {
        self.socketPath = socketPath
        self.onEvent = onEvent
        // Reports are applied on the main queue, where the view model lives; the listener's receive
        // timeout keeps a wrapper that connects and stalls from freezing the UI.
        listener = try UnixSocketListener(
            path: socketPath,
            queue: .main,
            onAcceptError: { [weak self] in self?.writeError("session report accept failed: errno \($0)") },
            onConnection: { [weak self] fd in self?.handle(clientFD: fd) }
        )
    }

    /// Binds and listens. There is no stop (see `UnixSocketListener`).
    func start() {
        do {
            try listener.start()
        } catch {
            writeError("session report socket start failed: \(error)")
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

