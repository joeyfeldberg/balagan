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
}
