import AppKit
import Darwin
import Foundation
import BalaganCore

/// A local **request/response** control socket. The `balagan` CLI connects, writes one JSON request
/// line, and reads back one JSON response line — letting the CLI drive the running app (list / create /
/// open tasks, query state).
///
/// Modeled on `SessionReportServer`, with two differences: it's bidirectional (writes a response), and
/// it runs accept + socket I/O on its **own background queue** so a slow/blocked read can never stall
/// the main thread. Each request's handler is hopped to the main thread (where `BoardViewModel` lives)
/// via `DispatchQueue.main.sync` — safe here because the main thread never waits on this queue.
final class ControlSocketServer: @unchecked Sendable {
    /// Handles one request on the **main actor** and returns the JSON-serialized response
    /// (a single object like `{"ok":true,"result":…}`, **without** a trailing newline — the server
    /// appends it). `@MainActor` so the handler can touch the view model / window; returns `Data`
    /// (rather than a dictionary) so the result is `Sendable`.
    typealias Handler = @MainActor @Sendable (_ method: String, _ params: [String: String]) -> Data

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.joeyfeldberg.balagan.control")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(socketPath: String, handler: @escaping Handler) throws {
        guard socketPath.utf8.count < UnixSocketHelpers.maxPathLength else {
            throw ControlSocketServerError.socketPathTooLong(socketPath)
        }
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let source = self.source {
                // The read source owns listenFD; its cancel handler closes it. Closing it here too
                // double-closes a dispatch-guarded fd, which raises EXC_GUARD (a hard crash on quit).
                source.cancel()
                self.source = nil
            } else if self.listenFD >= 0 {
                // No source was ever created (start failed) — nothing guards the fd, so close it here.
                Darwin.close(self.listenFD)
            }
            self.listenFD = -1
            unlink(self.socketPath)
        }
    }

    private func startOnQueue() {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            unlink(socketPath)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ControlSocketServerError.socketFailed(errno) }
            listenFD = fd

            var flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                flags |= O_NONBLOCK
                _ = fcntl(fd, F_SETFL, flags)
            }

            let address = UnixSocketHelpers.makeAddress(path: socketPath)
            guard UnixSocketHelpers.bind(fd, to: address) == 0 else {
                throw ControlSocketServerError.bindFailed(errno)
            }
            guard listen(fd, 8) == 0 else { throw ControlSocketServerError.listenFailed(errno) }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            self.source = source
            source.resume()
        } catch {
            if listenFD >= 0 {
                Darwin.close(listenFD)
                listenFD = -1
            }
            NSLog("Balagan control socket start failed: \(error)")
        }
    }

    private func acceptAvailableConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    NSLog("Balagan control accept failed: errno \(errno)")
                }
                return
            }
            var flags = fcntl(clientFD, F_GETFL, 0)
            if flags >= 0 {
                flags &= ~O_NONBLOCK
                _ = fcntl(clientFD, F_SETFL, flags)
            }
            var noSigpipe: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        // Read one newline-terminated request line. We're on the background queue, so a blocking read
        // here never stalls the UI.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.contains(0x0a) == false {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            break // EOF or error
        }

        let line = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let request = ControlWire.decodeRequestLine(line)
        let handler = self.handler

        // The handler runs on the main actor (it touches the view model / window); compute the reply,
        // write it, and close the socket there.
        DispatchQueue.main.async {
            let body: Data = MainActor.assumeIsolated {
                if let request {
                    return handler(request.method, request.params)
                }
                return Data(#"{"ok":false,"error":"malformed request"}"#.utf8)
            }
            var responseData = body
            responseData.append(0x0a)
            ControlSocketServer.write(responseData, to: clientFD)
            Darwin.close(clientFD)
        }
    }

    private static func write(_ data: Data, to clientFD: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(clientFD, base.advanced(by: written), data.count - written)
                if count <= 0 { break }
                written += count
            }
        }
    }
}

enum ControlSocketServerError: Error, CustomStringConvertible {
    case socketPathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var description: String {
        switch self {
        case let .socketPathTooLong(path):
            return "control socket path is too long for sockaddr_un: \(path)"
        case let .socketFailed(value):
            return "socket(AF_UNIX) failed with errno \(value)"
        case let .bindFailed(value):
            return "bind(AF_UNIX) failed with errno \(value)"
        case let .listenFailed(value):
            return "listen(AF_UNIX) failed with errno \(value)"
        }
    }
}
