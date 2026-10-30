import Darwin
import Foundation

/// A listening Unix-domain socket. Each accepted connection is handed to `onConnection` on `queue`,
/// already blocking, with a 2 s receive timeout (so a client that connects and stalls can't hang the
/// reader) and without SIGPIPE; the handler owns the fd and closes it.
///
/// There's deliberately no `stop()`: the read source owns the listening fd and closes it in its cancel
/// handler, and tearing it down on quit raced fd reuse into `EXC_GUARD` crashes. The kernel reaps it,
/// and the next launch unlinks and rebinds the path.
public final class UnixSocketListener: @unchecked Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String)
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)

        public var description: String {
            switch self {
            case let .pathTooLong(path): return "socket path is too long for sockaddr_un: \(path)"
            case let .socketFailed(value): return "socket(AF_UNIX) failed with errno \(value)"
            case let .bindFailed(value): return "bind(AF_UNIX) failed with errno \(value)"
            case let .listenFailed(value): return "listen(AF_UNIX) failed with errno \(value)"
            }
        }
    }

    public let path: String
    private let queue: DispatchQueue
    private let onConnection: (Int32) -> Void
    private let onAcceptError: (Int32) -> Void
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(
        path: String,
        queue: DispatchQueue,
        onAcceptError: @escaping (_ errno: Int32) -> Void = { _ in },
        onConnection: @escaping (_ fd: Int32) -> Void
    ) throws {
        guard path.utf8.count < UnixSocketHelpers.maxPathLength else { throw Failure.pathTooLong(path) }
        self.path = path
        self.queue = queue
        self.onAcceptError = onAcceptError
        self.onConnection = onConnection
    }

    /// Creates the socket's folder, replaces any stale socket file, then binds and listens. Call it on
    /// `queue`.
    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketFailed(errno) }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        guard UnixSocketHelpers.bind(fd, to: UnixSocketHelpers.makeAddress(path: path)) == 0 else {
            let failure = Failure.bindFailed(errno)
            Darwin.close(fd)
            throw failure
        }
        guard listen(fd, 8) == 0 else {
            let failure = Failure.listenFailed(errno)
            Darwin.close(fd)
            throw failure
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    private func acceptAvailableConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { onAcceptError(errno) }
                return
            }
            let flags = fcntl(clientFD, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK) }
            UnixSocketHelpers.setReceiveTimeout(clientFD, seconds: 2)
            var noSigpipe: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            onConnection(clientFD)
        }
    }
}
