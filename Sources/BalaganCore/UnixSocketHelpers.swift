import Darwin
import Foundation

/// Shared low-level plumbing for the AF_UNIX request/response sockets used by the control socket and
/// the session-report socket. Extracting the `sockaddr_un` path fill plus the `connect`/`bind` pointer
/// dance keeps the byte-identical boilerplate in one place; callers keep their own error enums and
/// framing (read/write loops, dispatch sources) so behavior is unchanged.
public enum UnixSocketHelpers {
    /// The number of bytes available in `sockaddr_un.sun_path` (roughly 104 on Darwin). A socket path
    /// must be strictly shorter than this to leave room for the terminating NUL.
    public static var maxPathLength: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /// Builds a `sockaddr_un` for the given AF_UNIX `path`, copying it into `sun_path` (bounded by
    /// `strncpy` so the copy always fits). Callers that must reject over-long paths should guard on
    /// `maxPathLength` first — this mirrors the pre-refactor code, which validated the length separately
    /// and mapped the failure to its own error type.
    public static func makeAddress(path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        _ = path.withCString { pathPointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: sunPathSize) {
                    strncpy($0, pathPointer, sunPathSize - 1)
                }
            }
        }
        return address
    }

    /// Calls `connect(2)` on `fd` for `address`, returning the raw status (0 on success; check `errno`
    /// on failure).
    public static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Calls `bind(2)` on `fd` for `address`, returning the raw status (0 on success; check `errno`
    /// on failure).
    public static func bind(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Makes a blocking read on `fd` give up after `seconds` instead of waiting forever, so a peer that
    /// connects and never sends (or never closes) can't hang the reader.
    public static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Which step of opening a client connection failed (each caller maps it to its own error type).
    enum ClientFailure: Error {
        case socket(errno: Int32)
        case pathTooLong
        case connect(errno: Int32)
    }

    /// A stream socket connected to `path`, with SIGPIPE off so a closed peer is an error, not a crash.
    /// The caller closes it.
    static func connectedClient(path: String) -> Result<Int32, ClientFailure> {
        guard path.utf8.count < maxPathLength else { return .failure(.pathTooLong) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket(errno: errno)) }
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, to: makeAddress(path: path)) == 0 else {
            let failure = errno
            Darwin.close(fd)
            return .failure(.connect(errno: failure))
        }
        return .success(fd)
    }

    /// Writes all of `data`, retrying short writes. Returns the errno of a failed write, nil on success.
    static func writeAll(_ data: Data, to fd: Int32) -> Int32? {
        data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard count > 0 else { return errno }
                written += count
            }
            return nil
        }
    }
}
